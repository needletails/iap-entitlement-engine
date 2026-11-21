//
//  GooglePlayProductPurchase.swift
//  iap-entitlement-engine
//

/// The fields the engine reads from the response of `purchases.products.get`.
///
/// The response does not repeat the product ID or the purchase token, so pass those to the
/// engine from the request you made.
public struct GooglePlayProductPurchase: Codable, Sendable, Equatable {
    /// 0 is purchased, 1 is cancelled, 2 is pending.
    public var purchaseState: Int
    /// 0 is yet to be consumed, 1 is consumed.
    public var consumptionState: Int?
    /// 0 is yet to be acknowledged, 1 is acknowledged.
    public var acknowledgementState: Int?
    public var orderId: String?
    /// Absent when one unit was bought.
    public var quantity: Int?
    /// How many of the units have not been refunded. A refund does not always take the item
    /// away, so the engine reads this only for a partial void. See ``Voided``.
    public var refundableQuantity: Int?
    /// The account ID your app attached to the purchase to say whose it is.
    public var obfuscatedExternalAccountId: String?
    public var purchaseTimeMillis: String?
    /// Present only for a purchase that was not paid for in the normal way: 0 is a test.
    public var purchaseType: Int?

    public init(
        purchaseState: Int,
        consumptionState: Int? = nil,
        acknowledgementState: Int? = nil,
        orderId: String? = nil,
        quantity: Int? = nil,
        refundableQuantity: Int? = nil,
        obfuscatedExternalAccountId: String? = nil,
        purchaseTimeMillis: String? = nil,
        purchaseType: Int? = nil
    ) {
        self.purchaseState = purchaseState
        self.consumptionState = consumptionState
        self.acknowledgementState = acknowledgementState
        self.orderId = orderId
        self.quantity = quantity
        self.refundableQuantity = refundableQuantity
        self.obfuscatedExternalAccountId = obfuscatedExternalAccountId
        self.purchaseTimeMillis = purchaseTimeMillis
        self.purchaseType = purchaseType
    }

    /// Google refunds a paid purchase that is not acknowledged within three days. Consuming a
    /// purchase acknowledges it too.
    public var needsAcknowledgement: Bool {
        purchaseState == 0 && acknowledgementState == 0
    }

    public var isConsumed: Bool {
        consumptionState == 1
    }

    public var isTestPurchase: Bool {
        purchaseType == 0
    }

    /// That Google has taken a purchase, or part of it, away from the buyer.
    ///
    /// Google reports this through the `VoidedPurchaseNotification` real-time developer
    /// notification, whose `refundType` is 1 for a full void and 2 for a partial one, and
    /// through the Voided Purchases API. A refund that leaves the item with the buyer appears
    /// in neither.
    ///
    /// A later release can add cases, so end a `switch` over it with `@unknown default`.
    @nonexhaustive
    public enum Voided: Sendable, Equatable {
        /// The whole purchase.
        case full
        /// Some of its units. The engine reads how many are left from the purchase's
        /// `refundableQuantity`, so pass a purchase fetched after the notification.
        case partial
    }
}
