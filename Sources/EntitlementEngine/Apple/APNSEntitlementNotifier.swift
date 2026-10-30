//
//  APNSEntitlementNotifier.swift
//  iap-entitlement-engine
//

import APNSCore
import Foundation

/// Sends entitlement messages to one Apple device through APNs.
public struct APNSEntitlementNotifier<Client: APNSClientProtocol>: EntitlementNotifier {
    private let client: Client
    private let topic: String
    private let deviceToken: String

    public init(client: Client, topic: String, deviceToken: String) {
        self.client = client
        self.topic = topic
        self.deviceToken = deviceToken
    }

    public func send(_ payload: IAPPayload, collapseID: String, expiresAt: Date) async throws {
        var notification = APNSAlertNotification(
            alert: .init(
                title: .raw(payload.title),
                subtitle: payload.subtitle.isEmpty ? nil : .raw(payload.subtitle),
                body: payload.body.isEmpty ? nil : .raw(payload.body)),
            expiration: .timeIntervalSince1970InSeconds(Int(expiresAt.timeIntervalSince1970)),
            priority: .immediately,
            topic: topic,
            payload: payload,
            sound: .default)
        notification.collapseID = collapseID
        try await client.sendAlertNotification(notification, deviceToken: deviceToken)
    }
}
