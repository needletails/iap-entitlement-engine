//
//  EntitlementNotifier.swift
//  iap-entitlement-engine
//

import Foundation

/// Delivers a message to one device. APNs and FCM implementations are included.
public protocol EntitlementNotifier: Sendable {
    func send(_ payload: IAPPayload, collapseID: String, expiresAt: Date) async throws
}
