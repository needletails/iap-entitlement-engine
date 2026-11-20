//
//  HTTPConnectionAPNSClient.swift
//  iap-entitlement-engine
//

import APNSCore
import Crypto
import Foundation
import HTTPConnectionKit
import HTTPTypes

/// An APNs client backed by HTTPConnectionKit, for ``APNSEntitlementNotifier``.
///
/// Create one for the life of the server and call ``shutdown()`` when it stops. A client that is
/// dropped without it keeps its connection open. Provider tokens are generated and reused
/// automatically.
public struct HTTPConnectionAPNSClient: APNSClientProtocol {
    /// How long a connection may sit unused before it is replaced. A gateway forgets an idle
    /// flow after a few minutes and resets the next request on it, and that push would be lost.
    static let idleLimit: Duration = .seconds(120)

    /// APNs only speaks HTTP/2, never redirects, and its responses are short.
    static let configuration = HTTPConnection.Configuration(
        protocols: .require(.http2),
        redirects: .disabled,
        decompression: .disabled,
        pool: .init(idleTimeout: idleLimit),
        maximumBufferedBodySize: 1 << 16)

    let ownsClient: Bool
    private let environment: APNSEnvironment
    private let client: HTTPConnection
    private let timeout: Duration
    private let nextValidToken: @Sendable () async throws -> String

    /// - Parameters:
    ///   - environment: `.production`, or `.development` for sandbox device tokens.
    ///   - privateKey: The APNs authentication key from the developer portal.
    ///   - timeout: How long one send may take.
    ///   - clock: Decides when a provider token has expired.
    public init<APNSClock: Clock>(
        environment: APNSEnvironment,
        privateKey: P256.Signing.PrivateKey,
        keyIdentifier: String,
        teamIdentifier: String,
        timeout: Duration = .seconds(30),
        clock: APNSClock = ContinuousClock()
    ) where APNSClock.Duration == Duration {
        self.init(
            environment: environment, privateKey: privateKey, keyIdentifier: keyIdentifier,
            teamIdentifier: teamIdentifier, client: HTTPConnection(configuration: Self.configuration),
            ownsClient: true, timeout: timeout, clock: clock)
    }

    /// Uses a connection the caller owns and shuts down.
    init<APNSClock: Clock>(
        environment: APNSEnvironment,
        privateKey: P256.Signing.PrivateKey,
        keyIdentifier: String,
        teamIdentifier: String,
        client: HTTPConnection,
        timeout: Duration = .seconds(30),
        clock: APNSClock = ContinuousClock()
    ) where APNSClock.Duration == Duration {
        self.init(
            environment: environment, privateKey: privateKey, keyIdentifier: keyIdentifier,
            teamIdentifier: teamIdentifier, client: client, ownsClient: false, timeout: timeout, clock: clock)
    }

    private init<APNSClock: Clock>(
        environment: APNSEnvironment,
        privateKey: P256.Signing.PrivateKey,
        keyIdentifier: String,
        teamIdentifier: String,
        client: HTTPConnection,
        ownsClient: Bool,
        timeout: Duration,
        clock: APNSClock
    ) where APNSClock.Duration == Duration {
        self.environment = environment
        self.client = client
        self.ownsClient = ownsClient
        self.timeout = timeout
        let tokens = APNSAuthenticationTokenManager(
            privateKey: privateKey,
            teamIdentifier: teamIdentifier,
            keyIdentifier: keyIdentifier,
            clock: clock)
        self.nextValidToken = { try await tokens.nextValidToken }
    }

    public func send(_ request: APNSRequest<some APNSMessage>) async throws -> APNSResponse {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let deviceToken = request.deviceToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? request.deviceToken
        let url = try PushTransportError.usable(URL(string: "\(environment.absoluteURL)/\(deviceToken)"))

        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.authorization] = try await nextValidToken()
        for (name, value) in request.headers {
            guard let field = HTTPField.Name(name) else { throw PushTransportError.invalidRequest }
            headers[field] = value
        }

        // Escaped slashes would double every "/" of a base64 payload and waste the 4 KB limit.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let body = try encoder.encode(request.message)
        let response: HCKResponse
        do {
            response = try await client.request(
                method: .post, url: url, headers: headers, body: body, options: .init(timeout: timeout))
        } catch {
            throw PushTransportError.wrapping(error)
        }

        let apnsID = Self.uuid(named: "apns-id", in: response)
        let apnsUniqueID = Self.uuid(named: "apns-unique-id", in: response)
        guard response.head.status.code != 200 else {
            return APNSResponse(apnsID: apnsID, apnsUniqueID: apnsUniqueID)
        }

        // An empty or non-JSON body must still surface as a typed error with the status code.
        let failure = response.body.flatMap { try? JSONDecoder().decode(APNSErrorResponse.self, from: $0) }
        throw APNSError(
            responseStatus: response.head.status.code,
            apnsID: apnsID,
            apnsUniqueID: apnsUniqueID,
            apnsResponse: failure,
            timestamp: failure?.timestampInSeconds.map { Date(timeIntervalSince1970: $0) })
    }

    public func shutdown() async throws {
        if ownsClient {
            await client.shutdown()
        }
    }

    private static func uuid(named name: String, in response: HCKResponse) -> UUID? {
        HTTPField.Name(name).flatMap { response.head.headerFields[$0] }.flatMap(UUID.init(uuidString:))
    }
}
