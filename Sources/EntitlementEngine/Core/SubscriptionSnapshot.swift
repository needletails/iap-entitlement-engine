//
//  SubscriptionSnapshot.swift
//  iap-entitlement-engine
//

import Foundation

/// A store-neutral view of one subscription. Apple receipts and Google Play purchases are both reduced to this.
public struct SubscriptionSnapshot: Sendable, Equatable {

    public enum Lifecycle: Sendable, Equatable {
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

    public enum SuspensionReason: Sendable, Equatable {
        case billing, paused
    }

    public enum RevocationReason: Sendable, Equatable {
        case appIssue, other
    }

    public enum Offer: Sendable, Equatable {
        case none, trial, introductory
    }

    public let productID: String
    public let lifecycle: Lifecycle
    public let expiresAt: Date?
    public let autoRenewEnabled: Bool
    public let offer: Offer

    public init(
        productID: String,
        lifecycle: Lifecycle,
        expiresAt: Date?,
        autoRenewEnabled: Bool,
        offer: Offer
    ) {
        self.productID = productID
        self.lifecycle = lifecycle
        self.expiresAt = expiresAt
        self.autoRenewEnabled = autoRenewEnabled
        self.offer = offer
    }
}
