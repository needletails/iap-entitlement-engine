//
//  FCMEntitlementNotifier.swift
//  iap-entitlement-engine
//

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

public enum FCMError: Error, Sendable, Equatable {
    /// The registration token is no longer valid. Stop sending to it.
    case unregistered
    case requestFailed(status: Int, body: String)
}

/// Supplies an OAuth 2 access token with the `https://www.googleapis.com/auth/firebase.messaging` scope.
///
/// Implement this with your service account. Tokens are requested per send, so cache them here.
public protocol FCMAccessTokenProvider: Sendable {
    func accessToken() async throws -> String
}

public struct FCMTransportResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol FCMTransport: Sendable {
    func post(url: String, headers: [String: String], body: Data) async throws -> FCMTransportResponse
}

/// The default transport, backed by AsyncHTTPClient.
public struct AsyncHTTPClientFCMTransport: FCMTransport {
    private static let maxResponseBytes = 1 << 20

    private let client: HTTPClient
    private let timeout: TimeAmount

    public init(client: HTTPClient = .shared, timeout: TimeAmount = .seconds(30)) {
        self.client = client
        self.timeout = timeout
    }

    public func post(url: String, headers: [String: String], body: Data) async throws -> FCMTransportResponse {
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        for (name, value) in headers {
            request.headers.add(name: name, value: value)
        }
        request.body = .bytes(ByteBuffer(bytes: body))

        let response = try await client.execute(request, timeout: timeout)
        let collected = try await response.body.collect(upTo: Self.maxResponseBytes)
        return FCMTransportResponse(status: Int(response.status.code), body: Data(collected.readableBytesView))
    }
}

/// Sends entitlement messages to one Android device through FCM HTTP v1.
public struct FCMEntitlementNotifier: EntitlementNotifier {
    private let projectID: String
    private let registrationToken: String
    private let accessTokenProvider: any FCMAccessTokenProvider
    private let transport: any FCMTransport
    private let now: @Sendable () -> Date

    public init(
        projectID: String,
        registrationToken: String,
        accessTokenProvider: any FCMAccessTokenProvider,
        transport: any FCMTransport = AsyncHTTPClientFCMTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectID = projectID
        self.registrationToken = registrationToken
        self.accessTokenProvider = accessTokenProvider
        self.transport = transport
        self.now = now
    }

    public func send(_ payload: IAPPayload, collapseID: String, expiresAt: Date) async throws {
        let ttl = max(0, Int(expiresAt.timeIntervalSince(now())))
        let request = Request(message: .init(
            token: registrationToken,
            notification: .init(
                title: payload.title,
                // FCM has no subtitle.
                body: [payload.subtitle, payload.body].filter { !$0.isEmpty }.joined(separator: "\n")),
            android: .init(ttl: "\(ttl)s", priority: "HIGH", collapseKey: collapseID),
            data: payload.data.map { ["payload": $0.base64EncodedString()] }))

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let project = projectID.addingPercentEncoding(withAllowedCharacters: allowed) ?? projectID
        let token = try await accessTokenProvider.accessToken()
        let response = try await transport.post(
            url: "https://fcm.googleapis.com/v1/projects/\(project)/messages:send",
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: JSONEncoder().encode(request))

        guard !(200..<300).contains(response.status) else { return }
        let failure = try? JSONDecoder().decode(ErrorResponse.self, from: response.body)
        if failure?.error.details?.contains(where: { $0.errorCode == "UNREGISTERED" }) == true {
            throw FCMError.unregistered
        }
        throw FCMError.requestFailed(
            status: response.status,
            body: String(decoding: response.body, as: UTF8.self))
    }

    private struct Request: Encodable {
        struct Message: Encodable {
            struct Notification: Encodable {
                let title: String
                let body: String
            }

            struct Android: Encodable {
                let ttl: String
                let priority: String
                let collapseKey: String
            }

            let token: String
            let notification: Notification
            let android: Android
            let data: [String: String]?
        }

        let message: Message
    }

    private struct ErrorResponse: Decodable {
        struct Body: Decodable {
            struct Detail: Decodable {
                let errorCode: String?
            }

            let details: [Detail]?
        }

        let error: Body
    }
}
