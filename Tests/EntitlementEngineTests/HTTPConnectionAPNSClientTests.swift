import APNSCore
import Crypto
import Foundation
import HTTPConnectionKit
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing
@testable import IAPEntitlementEngine

struct APNsWire: Sendable {
    var method = ""
    var uri = ""
    var headers: [String: String] = [:]
    var body = Data()
}

final class APNsWireRecord: Sendable {
    private let state = Mutex<[APNsWire]>([])

    var requests: [APNsWire] { state.withLock { $0 } }

    func append(_ wire: APNsWire) {
        state.withLock { $0.append(wire) }
    }
}

/// Answers every request with a fixed response, and records what arrived on the wire.
private final class APNsStubHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let record: APNsWireRecord
    private let status: HTTPResponseStatus
    private let headers: [String: String]
    private let body: String
    private var current = APNsWire()

    init(record: APNsWireRecord, status: HTTPResponseStatus, headers: [String: String], body: String) {
        self.record = record
        self.status = status
        self.headers = headers
        self.body = body
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            current = APNsWire(method: "\(head.method)", uri: head.uri)
            for header in head.headers {
                current.headers[header.name.lowercased()] = header.value
            }
        case .body(let buffer):
            current.body.append(contentsOf: buffer.readableBytesView)
        case .end:
            record.append(current)
            var responseHeaders = HTTPHeaders(headers.map { ($0.key, $0.value) })
            responseHeaders.add(name: "Content-Length", value: "\(body.utf8.count)")
            context.write(
                wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: responseHeaders))),
                promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: body)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

@Suite("HTTPConnection APNs client")
struct HTTPConnectionAPNSClientTests {
    static let apnsID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    let key = P256.Signing.PrivateKey()
    let record = APNsWireRecord()

    func withClient<T: Sendable>(
        status: HTTPResponseStatus = .ok,
        headers: [String: String] = [:],
        body: String = "",
        _ operation: (HTTPConnectionAPNSClient) async throws -> T
    ) async throws -> T {
        let record = record
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        APNsStubHandler(record: record, status: status, headers: headers, body: body))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(server.localAddress?.port)
        let connection = HTTPConnection()
        let client = HTTPConnectionAPNSClient(
            environment: .custom(url: "http://127.0.0.1", port: port),
            privateKey: key,
            keyIdentifier: "KEY123",
            teamIdentifier: "TEAM456",
            client: connection)
        do {
            let result = try await operation(client)
            await connection.shutdown()
            try await server.close()
            return result
        } catch {
            await connection.shutdown()
            try await server.close()
            throw error
        }
    }

    func request(deviceToken: String = "abcd") -> APNSRequest<APNSAlertNotification<IAPPayload>> {
        APNSRequest(
            message: APNSAlertNotification(
                alert: .init(title: .raw("Hello")),
                expiration: .timeIntervalSince1970InSeconds(1_800_000_000),
                priority: .immediately,
                topic: "com.example.app",
                payload: IAPPayload(title: "Hello", subtitle: "", body: "")),
            deviceToken: deviceToken,
            pushType: .alert,
            expiration: .timeIntervalSince1970InSeconds(1_800_000_000),
            priority: .immediately,
            apnsID: Self.apnsID,
            topic: "com.example.app",
            collapseID: "cancelled")
    }

    @Test func postsTheMessageToTheDevicePath() async throws {
        _ = try await withClient { try await $0.send(request()) }

        let wire = try #require(record.requests.first)
        #expect(wire.method == "POST")
        #expect(wire.uri == "/3/device/abcd")
        #expect(wire.headers["content-type"] == "application/json")
        let json = try #require(JSONSerialization.jsonObject(with: wire.body) as? [String: Any])
        let aps = try #require(json["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Hello")
    }

    @Test func sendsEveryAPNsHeader() async throws {
        _ = try await withClient { try await $0.send(request()) }

        let headers = try #require(record.requests.first?.headers)
        #expect(headers["apns-push-type"] == "alert")
        #expect(headers["apns-topic"] == "com.example.app")
        #expect(headers["apns-collapse-id"] == "cancelled")
        #expect(headers["apns-priority"] == "10")
        #expect(headers["apns-expiration"] == "1800000000")
        #expect(headers["apns-id"] == Self.apnsID.uuidString.lowercased())
    }

    @Test func signsAProviderTokenWithTheKey() async throws {
        _ = try await withClient { try await $0.send(request()) }

        let authorization = try #require(record.requests.first?.headers["authorization"])
        #expect(authorization.hasPrefix("bearer "))
        let parts = authorization.dropFirst("bearer ".count).split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let header = try #require(JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "KEY123")
        let claims = try #require(JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])
        #expect(claims["iss"] as? String == "TEAM456")

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    private func decode(_ base64URL: String) throws -> Data {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return try #require(Data(base64Encoded: value))
    }

    @Test func reusesTheProviderTokenAcrossSends() async throws {
        _ = try await withClient { client in
            _ = try await client.send(request())
            return try await client.send(request())
        }
        let tokens = Set(record.requests.compactMap { $0.headers["authorization"] })
        #expect(record.requests.count == 2)
        #expect(tokens.count == 1)
    }

    @Test func returnsTheIDsAPNsSendsBack() async throws {
        let unique = UUID()
        let response = try await withClient(headers: [
            "apns-id": Self.apnsID.uuidString,
            "apns-unique-id": unique.uuidString,
        ]) { try await $0.send(request()) }
        #expect(response.apnsID == Self.apnsID)
        #expect(response.apnsUniqueID == unique)
    }

    @Test func aDeviceTokenCannotEscapeTheDevicePath() async throws {
        _ = try await withClient { try await $0.send(request(deviceToken: "../../x?y")) }
        #expect(record.requests.first?.uri == "/3/device/..%2F..%2Fx%3Fy")
    }

    private func failure(
        status: HTTPResponseStatus,
        headers: [String: String] = [:],
        body: String
    ) async throws -> APNSError {
        let error: APNSError? = try await withClient(status: status, headers: headers, body: body) { client in
            do {
                _ = try await client.send(request())
                return nil
            } catch let error as APNSError {
                return error
            }
        }
        return try #require(error)
    }

    @Test func rejectionThrowsTheReason() async throws {
        let error = try await failure(
            status: .badRequest,
            headers: ["apns-id": Self.apnsID.uuidString],
            body: #"{"reason":"BadDeviceToken"}"#)
        #expect(error.responseStatus == 400)
        #expect(error.reason?.reason == "BadDeviceToken")
        #expect(error.apnsID == Self.apnsID)
    }

    /// `410` is how a server learns to stop using a token.
    @Test func unregisteredTokenCarriesItsTimestamp() async throws {
        let error = try await failure(
            status: .gone, body: #"{"reason":"Unregistered","timestamp":1800000000000}"#)
        #expect(error.responseStatus == 410)
        #expect(error.reason?.reason == "Unregistered")
        #expect(error.timestamp == now)
    }

    @Test func unreadableErrorBodyStillThrowsAPNSError() async throws {
        let error = try await failure(status: .internalServerError, body: "<html>")
        #expect(error.responseStatus == 500)
        #expect(error.reason == nil)
    }

    @Test func emptyErrorBodyStillThrowsAPNSError() async throws {
        let error = try await failure(status: .serviceUnavailable, body: "")
        #expect(error.responseStatus == 503)
        #expect(error.reason == nil)
    }

    @Test func defaultConnectionPrefersHTTP3AndNeverFollowsRedirects() {
        #expect(HTTPConnectionAPNSClient.configuration.protocols == .default)
        #expect(HTTPConnectionAPNSClient.configuration.protocols == .prefer(.http3, fallback: [.http2, .http1_1]))
        #expect(HTTPConnectionAPNSClient.configuration.redirects == .disabled)
    }

    /// An invalid configuration only fails on the first send, so catch it here.
    @Test func defaultConnectionsPassValidation() throws {
        _ = try HTTPConnection(validating: HTTPConnectionAPNSClient.configuration)
        _ = try HTTPConnection(validating: HTTPConnectionFCMTransport.configuration)
    }

    @Test func worksBehindTheNotifierAndTheEngine() async throws {
        let store = RecordingStore()
        _ = try await withClient { client in
            let engine = EntitlementEngine(
                storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
                yearlyProductID: "yearly", apnTopic: "com.example.app", deviceToken: "abcd", now: { now })
            return try await engine.processReceipt(
                apns: client, order: Order(id: orderID, isSubscribed: false), orderId: orderID.uuidString,
                latestReceiptInfo: LatestReceiptInfo(
                    productId: "monthly", expiresDateMs: milliseconds(now.addingTimeInterval(86_400))),
                pendingRenewalInfo: PendingRenewalInfo(autoRenewStatus: "1"))
        }
        #expect(store.updates.count == 1)
        #expect(record.requests.first?.headers["apns-collapse-id"] == "monthly-active")
    }

    /// The caller owns an injected connection, so closing the client must leave it usable.
    @Test func shutdownLeavesAnInjectedConnectionOpen() async throws {
        _ = try await withClient { client in
            try await client.shutdown()
            return try await client.send(request())
        }
        #expect(record.requests.count == 1)
    }
}
