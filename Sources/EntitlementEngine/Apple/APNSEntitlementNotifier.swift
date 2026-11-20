//
//  APNSEntitlementNotifier.swift
//  iap-entitlement-engine
//

import APNSCore
import Foundation

/// Sends entitlement messages to one Apple device through APNs.
///
/// The copy is sent twice: as the alert the system shows, and as `title`, `subtitle`, `body` and
/// `data` at the root of the payload for the app to read. APNs allows 4 KB in all, which leaves
/// about 2.7 KB for `data` with the default copy.
public struct APNSEntitlementNotifier: EntitlementNotifier {
    private let client: any APNSClientProtocol
    private let topic: String
    private let deviceToken: String

    /// - Parameters:
    ///   - client: Create it once and reuse it. ``HTTPConnectionAPNSClient`` is the one included.
    ///   - topic: The app's bundle ID.
    public init(client: any APNSClientProtocol, topic: String, deviceToken: String) {
        self.client = client
        self.topic = topic
        self.deviceToken = deviceToken
    }

    public func send(_ payload: IAPPayload, for notification: EntitlementNotification, expiresAt: Date) async throws {
        var alert = APNSAlertNotification(
            alert: .init(
                title: .raw(payload.title),
                subtitle: payload.subtitle.isEmpty ? nil : .raw(payload.subtitle),
                body: payload.body.isEmpty ? nil : .raw(payload.body)),
            expiration: .timeIntervalSince1970InSeconds(Int(expiresAt.timeIntervalSince1970)),
            priority: .immediately,
            topic: topic,
            payload: payload,
            sound: .default)
        alert.collapseID = notification.collapseID
        try await client.sendAlertNotification(alert, deviceToken: deviceToken)
    }
}
