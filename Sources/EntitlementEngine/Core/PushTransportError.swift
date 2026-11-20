//
//  PushTransportError.swift
//  iap-entitlement-engine
//

import Foundation
import HTTPConnectionKit

/// A push that could not be sent, or was never answered, by the included APNs and FCM clients.
///
/// A push the service answered and refused is an `APNSError` or an ``FCMError`` instead. A later
/// release can add cases, so end a `switch` over it with `@unknown default`.
@nonexhaustive
public enum PushTransportError: Error, Sendable, Equatable {
    /// The request could not be built, as from a malformed URL or header name. Retrying will
    /// not help.
    case invalidRequest
    /// The service did not answer in time.
    case timeout
    /// The connection failed or the answer could not be read. `description` is for logs.
    case connection(description: String)

    /// A URL that can be sent to: HTTP or HTTPS, with a host and a usable port.
    static func usable(_ url: URL?) throws -> URL {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false, (1...65_535).contains(url.port ?? 443) else {
            throw PushTransportError.invalidRequest
        }
        return url
    }

    /// Hides the transport's own error type, which is not part of this package's API.
    static func wrapping(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError: error
        case HTTPConnectionError.timeout: PushTransportError.timeout
        // The transport also reports a connection that closed without an answer as an invalid
        // request, so everything else it throws is a connection failure here.
        default: PushTransportError.connection(description: String(describing: error))
        }
    }
}
