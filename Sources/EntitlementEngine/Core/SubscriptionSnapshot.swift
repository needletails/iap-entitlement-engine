//
//  SubscriptionSnapshot.swift
//  iap-entitlement-engine
//

import Foundation

/// A store-neutral view of one subscription. Apple receipts, App Store signed data and Google Play
/// purchases are all reduced to this.
struct SubscriptionSnapshot: Sendable, Equatable {

    enum Lifecycle: Sendable, Equatable {
        /// The store reports no subscription.
        case notSubscribed
        /// Nothing can be concluded yet, so the order is left as it is.
        case pending
        /// This transaction was replaced by a higher tier, access continues on the new one.
        case upgraded
        /// Paid up or still inside a cancelled period. Access runs until `expiresAt`.
        case active
        /// Payment failed but the store keeps access open until `expiresAt`.
        case gracePeriod
        /// Access is blocked but the subscription can come back.
        case suspended(SuspensionReason)
        case expired
        /// Refunded or charged back. Access ends immediately.
        case revoked(RevocationReason)
    }

    enum SuspensionReason: Sendable, Equatable {
        case billing, paused
    }

    enum RevocationReason: Sendable, Equatable {
        case appIssue, other
    }

    enum Offer: Sendable, Equatable {
        case none, trial, introductory
    }

    let productID: String
    let lifecycle: Lifecycle
    let expiresAt: Date?
    let autoRenewEnabled: Bool
    let offer: Offer
    /// The data is about a period before the subscription's latest one, so its product may be
    /// one the subscriber has since left. It can keep access open, but not start it or name
    /// the order's product.
    var isEarlierPeriod = false
}
