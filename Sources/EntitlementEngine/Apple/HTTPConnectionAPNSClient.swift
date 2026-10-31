//
//  HTTPConnectionAPNSClient.swift
//  iap-entitlement-engine
//

import APNSCore
import Crypto
import Foundation
import HTTPConnectionKit
import HTTPTypes

/// An APNs client backed by HTTPConnectionKit.
///
/// Pass it to ``EntitlementEngine/processReceipt(apns:order:orderId:latestReceiptInfo:pendingRenewalInfo:)``
/// or wrap it in ``APNSEntitlementNotifier``. Provider tokens are generated and reused automatically.
public struct HTTPConnectionAPNSClient: APNSClientProtocol {
    /// Tries HTTP/3 and downgrades over TCP when QUIC fails, where APNs selects HTTP/2. APNs never
    /// redirects, and its responses are short.
    static let configuration = HTTPConnection.Configuration(
        protocols: .default,
        redirects: .disabled,
        decompression: .disabled,
        maximumBufferedBodySize: 1 << 16)

    private let environment: APNSEnvironment
    private let client: HTTPConnection
    private let ownsClient: Bool
    private let timeout: Duration
    private let nextValidToken: @Sendable () async throws -> String

    /// - Parameters:
    ///   - environment: `.production`, or `.development` for sandbox device tokens.
    ///   - privateKey: The APNs authentication key from the developer portal.
    ///   - client: A connection to reuse. It has to allow HTTP/2 or later, and you stay responsible
    ///     for shutting it down.
    ///   - clock: Decides when a provider token has expired.
    public init<APNSClock: Clock>(
        environment: APNSEnvironment,
        privateKey: P256.Signing.PrivateKey,
        keyIdentifier: String,
        teamIdentifier: String,
        client: HTTPConnection? = nil,
        timeout: Duration = .seconds(30),
        clock: APNSClock = ContinuousClock()
    ) where APNSClock.Duration == Duration {
        self.environment = environment
        self.client = client ?? HTTPConnection(configuration: Self.configuration)
        self.ownsClient = client == nil
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
        guard let url = URL(string: "\(environment.absoluteURL)/\(deviceToken)") else {
            throw HTTPConnectionError.invalidRequest
        }

        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.authorization] = try await nextValidToken()
        for (name, value) in request.headers {
            guard let field = HTTPField.Name(name) else { throw HTTPConnectionError.invalidRequest }
            headers[field] = value
        }

        let response = try await client.request(
            method: .post,
            url: url,
            headers: headers,
            body: JSONEncoder().encode(request.message),
            options: .init(timeout: timeout))

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
