//
//  OneTimeProduct.swift
//  iap-entitlement-engine
//

import Foundation

/// A product that is bought with a single payment, as opposed to a subscription that renews.
public struct OneTimeProduct: Sendable, Hashable {
    /// What the buyer gets for the payment.
    ///
    /// A later release can add cases, so end a `switch` over it with `@unknown default`.
    @nonexhaustive
    public enum Kind: Sendable, Hashable {
        /// Can be bought again and again, such as coins. Each purchase is granted once, with
        /// its quantity.
        case consumable
        /// Bought once and owned until it is refunded, such as a lifetime unlock.
        case nonConsumable
        /// Access for a fixed time that does not renew, such as a season pass. Neither store
        /// reports when it ends, so you say how long it lasts.
        case nonRenewing(duration: TimeInterval)
    }

    /// The store product ID.
    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}
