//
//  PurchaseResult.swift
//  iap-entitlement-engine
//

import Foundation

/// What one ``PurchaseEngine`` call did.
///
/// A process call throws only when nothing was saved. Everything after the save, including a
/// push that failed, is reported here. A later release can add fields.
public struct PurchaseResult: Sendable {
    /// A later release can add cases, so end a `switch` over it with `@unknown default`.
    @nonexhaustive
    public enum Outcome: Sendable, Equatable {
        /// A purchase the engine had not seen. ``PurchaseResult/quantityChange`` units are the
        /// buyer's.
        case granted
        /// A refund or revocation the engine had not seen. ``PurchaseResult/quantityChange``
        /// is negative, or zero when nothing had been granted.
        case revoked
        /// Apple reversed a refund, or replaced it with a newer one that takes back less. The
        /// units in ``PurchaseResult/quantityChange`` are the buyer's again.
        case reinstated
        /// Seen before. Do nothing.
        case unchanged
        /// Not paid for yet. Nothing was saved, and the store reports again when it is.
        case pending
        /// The product is not one of the engine's one-time products. Nothing was saved.
        case ignored
    }

    public let outcome: Outcome
    /// The purchase as it now stands. `nil` when the outcome is `pending` or `ignored`.
    public let record: PurchaseRecord?
    /// The product bought. `nil` when the outcome is `ignored`.
    public let product: OneTimeProduct?
    /// The units added to what the buyer holds, or taken away when negative. The delegate was
    /// given the same number to apply with the save, so do not apply it again from here.
    public let quantityChange: Int
    /// Whether the delegate saved ``record``.
    public let didSave: Bool
    /// The message that was due, whether or not it went out.
    public let notification: EntitlementNotification?
    /// Why the message did not go out. `nil` when it was sent, or when none was due.
    public let pushFailure: (any Error)?

    /// When a non-renewing purchase stops giving access. `nil` for the other kinds, and once
    /// the purchase is fully refunded.
    public var accessExpiresAt: Date? {
        guard let record, !record.isRevoked else { return nil }
        return record.expiresAt
    }

    /// The engine builds its own results. This is for a test double of the engine.
    public init(
        outcome: Outcome,
        record: PurchaseRecord? = nil,
        product: OneTimeProduct? = nil,
        quantityChange: Int = 0,
        didSave: Bool = false,
        notification: EntitlementNotification? = nil,
        pushFailure: (any Error)? = nil
    ) {
        self.outcome = outcome
        self.record = record
        self.product = product
        self.quantityChange = quantityChange
        self.didSave = didSave
        self.notification = notification
        self.pushFailure = pushFailure
    }
}
