//
//  GooglePlayAdapter.swift
//  iap-entitlement-engine
//

import Foundation

/// Reduces a Google Play purchase to a ``SubscriptionSnapshot``.
enum GooglePlayAdapter {

    /// - Parameter isRevoked: Pass `true` for a `SUBSCRIPTION_REVOKED` notification. Google reports
    ///   revocations as plain `SUBSCRIPTION_STATE_EXPIRED`, so the purchase alone cannot show one.
    static func snapshot(
        purchase: GooglePlaySubscriptionPurchase,
        catalog: ProductCatalog,
        isRevoked: Bool
    ) throws -> SubscriptionSnapshot {
        let lifecycle = try lifecycle(of: purchase, isRevoked: isRevoked)
        let items = purchase.lineItems ?? []
        let matching = items.filter { catalog.contains(identifier(of: $0, catalog: catalog)) }
        let candidates = matching.isEmpty ? items : matching

        let needsExpiry = lifecycle == .active || lifecycle == .gracePeriod
        let dated = try candidates.map { item -> (item: GooglePlaySubscriptionPurchase.LineItem, expiry: Date?) in
            let expiry = item.expiryTime.flatMap(parseRFC3339)
            if needsExpiry, expiry == nil {
                throw EntitlementError.invalidDate(field: "expiryTime")
            }
            return (item, expiry)
        }
        let latest = dated.max { ($0.expiry ?? .distantPast) < ($1.expiry ?? .distantPast) }

        if needsExpiry, latest == nil {
            throw EntitlementError.invalidDate(field: "expiryTime")
        }
        return SubscriptionSnapshot(
            productID: latest.map { identifier(of: $0.item, catalog: catalog) } ?? "",
            lifecycle: lifecycle,
            expiresAt: latest?.expiry,
            autoRenewEnabled: latest?.item.autoRenewingPlan?.autoRenewEnabled ?? false,
            offer: offer(of: latest?.item))
    }

    private static func lifecycle(
        of purchase: GooglePlaySubscriptionPurchase,
        isRevoked: Bool
    ) throws -> SubscriptionSnapshot.Lifecycle {
        if isRevoked {
            return .revoked(.other)
        }
        // The replacement purchase token owns the entitlement from here on.
        if purchase.canceledStateContext?.replacementCancellation != nil {
            return .pending
        }
        switch purchase.subscriptionState {
        case "SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_CANCELED":
            return .active
        case "SUBSCRIPTION_STATE_IN_GRACE_PERIOD":
            return .gracePeriod
        case "SUBSCRIPTION_STATE_ON_HOLD":
            return .suspended(.billing)
        case "SUBSCRIPTION_STATE_PAUSED":
            return .suspended(.paused)
        case "SUBSCRIPTION_STATE_EXPIRED":
            return .expired
        case "SUBSCRIPTION_STATE_PENDING", "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED":
            return .pending
        default:
            throw EntitlementError.unsupportedState(purchase.subscriptionState)
        }
    }

    /// Play usually sells one product with several base plans, so a base plan can be the catalog entry.
    private static func identifier(
        of item: GooglePlaySubscriptionPurchase.LineItem,
        catalog: ProductCatalog
    ) -> String {
        if let basePlan = item.offerDetails?.basePlanId, catalog.contains(basePlan) {
            return basePlan
        }
        return item.productId
    }

    private static func offer(of item: GooglePlaySubscriptionPurchase.LineItem?) -> SubscriptionSnapshot.Offer {
        if item?.offerPhase?.freeTrial != nil {
            return .trial
        }
        if item?.offerPhase?.introductoryPrice != nil {
            return .introductory
        }
        return .none
    }

    /// Google sends anywhere from zero to nine fractional digits.
    private static func parseRFC3339(_ value: String) -> Date? {
        var whole = value
        var fraction: TimeInterval = 0
        if let dot = value.firstIndex(of: "."), let zone = value.lastIndex(of: "Z"), dot < zone {
            guard let parsed = TimeInterval("0" + value[dot..<zone]) else { return nil }
            fraction = parsed
            whole = String(value[..<dot]) + "Z"
        }
        return ISO8601DateFormatter().date(from: whole)?.addingTimeInterval(fraction)
    }
}
