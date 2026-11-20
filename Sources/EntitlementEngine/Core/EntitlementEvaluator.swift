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
    /// Products that are no longer sold but still have subscribers.
    var retired: Set<String> = []

    func evaluate(_ snapshot: SubscriptionSnapshot, order: Order, now: Date) -> EntitlementDecision {
        let wasSubscribed = order.isSubscribed == true

        // What happens to another product, such as a refunded consumable, says nothing about this
        // subscription.
        guard concerns(order, productID: snapshot.productID) else {
            return EntitlementDecision()
        }

        switch snapshot.lifecycle {
        case .pending:
            return EntitlementDecision()
        case .upgraded:
            // Once the new product is on the order this is a replay, and was announced the first time.
            let stillOnTheReplacedProduct = wasSubscribed && order.productName == snapshot.productID
            return EntitlementDecision(notification: stillOnTheReplacedProduct ? .upgraded : nil)
        case .revoked(let reason):
            let notification: EntitlementNotification = reason == .appIssue ? .cancelledAppIssue : .cancelled
            return EntitlementDecision(isSubscribed: false, notification: wasSubscribed ? notification : nil)
        case .notSubscribed:
            return EntitlementDecision(isSubscribed: false, notification: wasSubscribed ? .notSubscribed : nil)
        case .expired, .suspended(.paused):
            return EntitlementDecision(isSubscribed: false)
        case .suspended(.billing):
            return EntitlementDecision(isSubscribed: false, notification: wasSubscribed ? .billingIssue : nil)
        case .gracePeriod where snapshot.isEarlierPeriod:
            // The store is keeping the subscription open, so a subscriber keeps access and is
            // asked for payment. Nothing here says which product they are on now.
            guard wasSubscribed, let expiresAt = snapshot.expiresAt, expiresAt > now else {
                return EntitlementDecision()
            }
            return EntitlementDecision(isSubscribed: true, notification: .billingIssue)
        case .active, .gracePeriod:
            return evaluateAccess(snapshot, order: order, wasSubscribed: wasSubscribed, now: now)
        }
    }

    /// A store reporting no subscription names no product, and still counts. So does a retired
    /// product for the subscriber who holds it, so their refund or expiry is not lost.
    func concerns(_ order: Order, productID: String) -> Bool {
        productID.isEmpty || catalog.contains(productID) || order.productName == productID
    }

    private func evaluateAccess(
        _ snapshot: SubscriptionSnapshot,
        order: Order,
        wasSubscribed: Bool,
        now: Date
    ) -> EntitlementDecision {
        // A product that has left the catalog keeps the subscriber it already has for as long as
        // the store reports a running period. It never starts a subscription, so a product name
        // the caller wrote cannot buy access. The one exception is a product the app itself names
        // as retired: the order that holds it gets access back when the store resumes charging,
        // as after a billing retry, an account hold or a pause.
        let isSold = catalog.contains(snapshot.productID)
        let holdsIt = !snapshot.productID.isEmpty && order.productName == snapshot.productID
        let keepsARetiredProduct = holdsIt && (wasSubscribed || retired.contains(snapshot.productID))
        guard isSold || keepsARetiredProduct else {
            return EntitlementDecision(isSubscribed: false, notification: wasSubscribed ? .notSubscribed : nil)
        }
        guard let expiresAt = snapshot.expiresAt, expiresAt > now else {
            return EntitlementDecision(isSubscribed: false)
        }

        let notification: EntitlementNotification?
        if snapshot.lifecycle == .gracePeriod {
            notification = .billingIssue
        } else if !wasSubscribed, !isSold {
            // A retired product has no plan to announce.
            notification = nil
        } else if !wasSubscribed {
            switch snapshot.offer {
            case .trial: notification = .trialStarted
            case .introductory: notification = .introOfferStarted
            case .none: notification = catalog.activeNotification(for: snapshot.productID)
            }
        } else if let held = order.productName, !held.isEmpty, held != snapshot.productID {
            // An order saved as subscribed without its product is adopted, not welcomed again.
            notification = catalog.activeNotification(for: snapshot.productID)
        } else if !snapshot.autoRenewEnabled, expiresAt.timeIntervalSince(now) <= Self.expiryWarningWindow {
            notification = .expiringToday
        } else {
            notification = nil
        }
        return EntitlementDecision(isSubscribed: true, productName: snapshot.productID, notification: notification)
    }
}
