//
//  FCMEntitlementNotifier.swift
//  iap-entitlement-engine
//

import Foundation
import HTTPConnectionKit
import HTTPTypes

/// Why FCM did not accept a message.
///
/// A later release can add cases, so end a `switch` over it with `@unknown default`.
@nonexhaustive
public enum FCMError: Error, Sendable, Equatable {
    /// The registration token is no longer valid. Stop sending to it.
    case unregistered
    /// - Parameters:
    ///   - code: FCM's error code, such as `QUOTA_EXCEEDED` or `UNAVAILABLE`, when the response
    ///     carried one.
    ///   - retryAfter: The seconds Google asked the sender to wait, from the `Retry-After`
    ///     header, whether it gave seconds or a date. `nil` when it gave neither.
    case requestFailed(status: Int, code: String?, retryAfter: TimeInterval?, body: String)
}

/// Supplies an OAuth 2 access token with the `https://www.googleapis.com/auth/firebase.messaging` scope.
///
/// Implement this with your service account. Tokens are requested per send, so cache them here.
public protocol FCMAccessTokenProvider: Sendable {
    func accessToken() async throws -> String
}

/// What a transport read back from FCM.
public struct FCMTransportResponse: Sendable {
    public let status: Int
    /// The response header fields. Their names are matched without regard to case.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Sends one request to FCM. Implement it to use your own HTTP client.
public protocol FCMTransport: Sendable {
    func post(url: String, headers: [String: String], body: Data) async throws -> FCMTransportResponse
}

/// The default transport, backed by HTTPConnectionKit.
///
/// Every instance shares one client for the life of the process. Its connection is replaced
/// after two minutes without a push.
public struct HTTPConnectionFCMTransport: FCMTransport {
    /// How long a connection may sit unused before it is replaced. A gateway forgets an idle
    /// flow after a few minutes and resets the next request on it, and that push would be lost.
    static let idleLimit: Duration = .seconds(120)

    /// Tries HTTP/3 and downgrades when QUIC fails. FCM never redirects, so a redirect is reported as a failed send instead of being followed.
    static let configuration = HTTPConnection.Configuration(
        protocols: .default,
        redirects: .disabled,
        pool: .init(idleTimeout: idleLimit),
        maximumBufferedBodySize: 1 << 20)

    private static let shared = HTTPConnection(configuration: configuration)

    private let client: HTTPConnection
    private let timeout: Duration

    /// - Parameter timeout: How long one send may take.
    public init(timeout: Duration = .seconds(30)) {
        self.init(client: Self.shared, timeout: timeout)
    }

    /// Uses a connection the caller owns and shuts down.
    init(client: HTTPConnection, timeout: Duration = .seconds(30)) {
        self.client = client
        self.timeout = timeout
    }

    public func post(url: String, headers: [String: String], body: Data) async throws -> FCMTransportResponse {
        let target = try PushTransportError.usable(URL(string: url))
        var fields = HTTPFields()
        for (name, value) in headers {
            guard let field = HTTPField.Name(name) else { throw PushTransportError.invalidRequest }
            fields[field] = value
        }

        let response: HCKResponse
        do {
            response = try await client.request(
                method: .post, url: target, headers: fields, body: body, options: .init(timeout: timeout))
        } catch {
            throw PushTransportError.wrapping(error)
        }
        var received: [String: String] = [:]
        for field in response.head.headerFields {
            received[field.name.canonicalName] = field.value
        }
        return FCMTransportResponse(
            status: response.head.status.code, headers: received, body: response.body ?? Data())
    }
}

/// Sends entitlement messages to one Android device through FCM HTTP v1.
///
/// The copy goes in the notification. ``IAPPayload/data`` is sent base64-encoded as the data
/// field `payload`.
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
        transport: any FCMTransport = HTTPConnectionFCMTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectID = projectID
        self.registrationToken = registrationToken
        self.accessTokenProvider = accessTokenProvider
        self.transport = transport
        self.now = now
    }

    public func send(_ payload: IAPPayload, for notification: EntitlementNotification, expiresAt: Date) async throws {
        let ttl = max(0, Int(expiresAt.timeIntervalSince(now())))
        let request = Request(message: .init(
            token: registrationToken,
            notification: .init(
                title: payload.title,
                // FCM has no subtitle.
                body: [payload.subtitle, payload.body].filter { !$0.isEmpty }.joined(separator: "\n")),
            // The tag is what replaces a notification that is already on screen. FCM always
            // collapses notification messages and ignores the collapse key for them.
            android: .init(
                ttl: "\(ttl)s", priority: "HIGH", collapseKey: notification.collapseID,
                notification: .init(tag: notification.collapseID)),
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
        let code = failure?.error.details?.lazy.compactMap(\.errorCode).first ?? failure?.error.status
        if code == "UNREGISTERED" {
            throw FCMError.unregistered
        }
        let retryAfter = response.headers.first { $0.key.lowercased() == "retry-after" }
            .flatMap { Self.wait(from: $0.value, now: now()) }
        throw FCMError.requestFailed(
            status: response.status,
            code: code,
            retryAfter: retryAfter,
            body: String(decoding: response.body, as: UTF8.self))
    }

    /// `Retry-After` is either whole seconds or an HTTP date. Anything else is not a wait.
    static func wait(from value: String, now: Date) -> TimeInterval? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if let seconds = UInt32(text) {
            return TimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        return formatter.date(from: text).map { max(0, $0.timeIntervalSince(now)) }
    }

    private struct Request: Encodable {
        struct Message: Encodable {
            struct Notification: Encodable {
                let title: String
                let body: String
            }

            struct Android: Encodable {
                struct Notification: Encodable {
                    let tag: String
                }

                let ttl: String
                let priority: String
                let collapseKey: String
                let notification: Notification
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

            let status: String?
            let details: [Detail]?
        }

        let error: Body
    }
}
