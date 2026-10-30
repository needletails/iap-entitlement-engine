//
//  EntitlementEvaluator.swift
//  iap-entitlement-engine
//

import Foundation

/// What should happen to an order. `nil` fields mean "leave as it is".
struct EntitlementDecision: Sendable, Equatable {
    var isSubscribed: Bool?
    var productName: String?
    var notification: EntitlementNotification?
}

/// The entitlement rules, shared by every store. Pure, so every rule is testable without a network.
///
/// Pushes fire on transitions rather than on every evaluation, which keeps webhook retries and
/// periodic re-checks from repeating one-off messages.
struct EntitlementEvaluator: Sendable {
    /// How close to expiry a non-renewing subscriber gets warned.
    private static let expiryWarningWindow: TimeInterval = 86_400

    let catalog: ProductCatalog

    func evaluate(_ snapshot: SubscriptionSnapshot, order: Order, now: Date) -> EntitlementDecision {
        let wasSubscribed = order.isSubscribed == true

        switch snapshot.lifecycle {
        case .pending:
            return EntitlementDecision()
        case .upgraded:
            return EntitlementDecision(notification: .upgraded)
        case .revoked(let reason):
            let notification: EntitlementNotification = reason == .appIssue ? .cancelledAppIssue : .cancelled
            return EntitlementDecision(isSubscribed: false, notification: wasSubscribed ? notification : nil)
        case .notSubscribed:
            return EntitlementDecision(isSubscribed: false, notification: wasSubscribed ? .notSubscribed : nil)
        case .expired, .suspended(.paused):
            return EntitlementDecision(isSubscribed: false)
        case .suspended(.billing):
            return EntitlementDecision(isSubscribed: false, notification: wasSubscribed ? .billingIssue : nil)
        case .active, .gracePeriod:
            return evaluateAccess(snapshot, order: order, wasSubscribed: wasSubscribed, now: now)
        }
    }

    private func evaluateAccess(
        _ snapshot: SubscriptionSnapshot,
        order: Order,
        wasSubscribed: Bool,
        now: Date
    ) -> EntitlementDecision {
        guard catalog.contains(snapshot.productID) else {
            return EntitlementDecision(isSubscribed: false, notification: wasSubscribed ? .notSubscribed : nil)
        }
        guard let expiresAt = snapshot.expiresAt, expiresAt > now else {
            return EntitlementDecision(isSubscribed: false)
        }

        let notification: EntitlementNotification?
        if snapshot.lifecycle == .gracePeriod {
            notification = .billingIssue
        } else if !wasSubscribed {
            switch snapshot.offer {
            case .trial: notification = .trialStarted
            case .introductory: notification = .introOfferStarted
            case .none: notification = catalog.activeNotification(for: snapshot.productID)
            }
        } else if order.productName != snapshot.productID {
            notification = catalog.activeNotification(for: snapshot.productID)
        } else if !snapshot.autoRenewEnabled, expiresAt.timeIntervalSince(now) <= Self.expiryWarningWindow {
            notification = .expiringToday
        } else {
            notification = nil
        }
        return EntitlementDecision(isSubscribed: true, productName: snapshot.productID, notification: notification)
    }
}
