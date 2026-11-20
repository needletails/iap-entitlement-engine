//
//  EntitlementNotifier.swift
//  iap-entitlement-engine
//

import Foundation

/// Delivers a message to one device. APNs and FCM implementations are included.
public protocol EntitlementNotifier: Sendable {
    /// - Parameters:
    ///   - payload: The copy to show.
    ///   - notification: Which message this is. Its ``EntitlementNotification/collapseID`` lets
    ///     a device replace an earlier copy of the same message.
    ///   - expiresAt: When to stop trying to deliver it.
    func send(_ payload: IAPPayload, for notification: EntitlementNotification, expiresAt: Date) async throws
}
