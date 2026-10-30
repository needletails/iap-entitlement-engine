import Foundation
import HTTPConnectionKit
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing
@testable import IAPEntitlementEngine

/// Answers every POST with a fixed status, and records what arrived on the wire.
private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    struct Received: Sendable {
        var method = ""
        var authorization = ""
        var body = ""
    }

    private let received: Mutex<Received>.Box
    private let status: HTTPResponseStatus
    private let body: String
    private var current = Received()

    init(received: Mutex<Received>.Box, status: HTTPResponseStatus, body: String) {
        self.received = received
        self.status = status
        self.body = body
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            current.method = "\(head.method)"
            current.authorization = head.headers.first(name: "Authorization") ?? ""
        case .body(let buffer):
            current.body += String(buffer: buffer)
        case .end:
            received.mutex.withLock { $0 = current }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(body.utf8.count)")
            if status.code / 100 == 3 {
                headers.add(name: "Location", value: "/elsewhere")
            }
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: body)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}

private extension Mutex where Value: Sendable {
    final class Box: Sendable {
        let mutex: Mutex<Value>

        init(_ value: Value) {
            mutex = Mutex(value)
        }
    }
}

@Suite("HTTPConnection transport")
struct HTTPConnectionTransportTests {
    private func startServer(
        status: HTTPResponseStatus,
        body: String = "{}",
        received: Mutex<EchoHandler.Received>.Box = .init(.init())
    ) async throws -> any Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(EchoHandler(received: received, status: status, body: body))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    @Test func sendsARealHTTPRequestAndReadsTheResponse() async throws {
        let received = Mutex<EchoHandler.Received>.Box(.init())
        let server = try await startServer(status: .created, received: received)
        let port = try #require(server.localAddress?.port)

        let client = HTTPConnection()
        let response: FCMTransportResponse
        do {
            response = try await HTTPConnectionFCMTransport(client: client).post(
                url: "http://127.0.0.1:\(port)/send",
                headers: ["Authorization": "Bearer t"],
                body: Data("hello".utf8))
        } catch {
            await client.shutdown()
            try await server.close()
            throw error
        }
        await client.shutdown()
        try await server.close()

        #expect(response.status == 201)
        #expect(response.body == Data("{}".utf8))
        let wire = received.mutex.withLock { $0 }
        #expect(wire.method == "POST")
        #expect(wire.authorization == "Bearer t")
        #expect(wire.body == "hello")
    }

    @Test func defaultTransportReportsARedirectInsteadOfFollowingIt() async throws {
        let server = try await startServer(status: .found)
        let port = try #require(server.localAddress?.port)
        let result = await Result(catching: {
            try await HTTPConnectionFCMTransport().post(
                url: "http://127.0.0.1:\(port)/send", headers: [:], body: Data("hello".utf8))
        })
        try await server.close()
        #expect(try result.get().status == 302)
    }

    @Test func defaultTransportReturnsErrorStatusesToTheNotifier() async throws {
        let server = try await startServer(status: .notFound)
        let port = try #require(server.localAddress?.port)
        let result = await Result(catching: {
            try await HTTPConnectionFCMTransport().post(
                url: "http://127.0.0.1:\(port)/send", headers: [:], body: Data("hello".utf8))
        })
        try await server.close()
        #expect(try result.get().status == 404)
    }

    @Test func defaultTransportRefusesAnOversizedResponse() async throws {
        let server = try await startServer(status: .ok, body: String(repeating: "x", count: (1 << 20) + 1))
        let port = try #require(server.localAddress?.port)
        let result = await Result(catching: {
            try await HTTPConnectionFCMTransport().post(
                url: "http://127.0.0.1:\(port)/send", headers: [:], body: Data("hello".utf8))
        })
        try await server.close()
        #expect(throws: (any Error).self) { try result.get() }
    }

    @Test func invalidHeaderNameIsRejectedBeforeSending() async {
        await #expect(throws: HTTPConnectionError.invalidRequest) {
            _ = try await HTTPConnectionFCMTransport().post(
                url: "http://127.0.0.1:1/send", headers: ["bad name": "x"], body: Data())
        }
    }
}
