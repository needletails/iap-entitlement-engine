//
//  PurchaseRecord.swift
//  iap-entitlement-engine
//

import Foundation

/// One one-time purchase as the engine last saw it. Store it keyed by ``transactionID``.
///
/// The record is what stops a purchase from being granted twice, so keep it for as long as the
/// store can resend the purchase. Do not delete it when it is refunded.
public struct PurchaseRecord: Codable, Sendable, Equatable {
    /// Which store sold it.
    ///
    /// A later release can add cases, so end a `switch` over it with `@unknown default`.
    @nonexhaustive
    public enum Store: String, Codable, Sendable {
        case appStore = "app-store"
        case googlePlay = "google-play"
    }

    /// Apple's original transaction ID, or Google's purchase token. Unique for each purchase
    /// within its ``store``.
    public let transactionID: String
    public let productID: String
    public let store: Store
    /// Whose purchase this is: the value you passed to the engine, or else the account token
    /// your app attached to the purchase (`appAccountToken` on the App Store,
    /// `obfuscatedExternalAccountId` on Google Play). It is `nil` only for a purchase that was
    /// first seen fully refunded and that no later event has named a buyer for. Such a record
    /// holds no units, and none are given back to it until an event names the buyer.
    public var accountID: String?
    /// Google's order ID, which its voided purchase reports name. `nil` on the App Store.
    public var orderID: String?
    /// How many units were bought. Always 1 unless the product is consumable.
    public var quantity: Int
    public var purchasedAt: Date
    /// When a non-renewing purchase stops giving access. `nil` for the other kinds.
    public var expiresAt: Date?
    /// How many of the units are refunded or revoked right now.
    public var revokedQuantity: Int
    /// When the engine first saw the refund or revocation that is in force. `nil` when none is.
    public var revokedAt: Date?
    /// Apple's `revocationDate` of the newest refund that has not been reversed. A prorated
    /// refund that took nothing sets it too.
    public var storeRevokedAt: Date?
    /// The `signedDate` of the newest refund reversal Apple has sent. Every refund dated
    /// before it is reversed, whether it arrived before the reversal or arrives after.
    public var reversedThrough: Date?
    /// When the engine last gave units back because a refund was reversed.
    public var reinstatedAt: Date?
    /// A sandbox or test purchase.
    public var isTest: Bool
    /// The buyer got it through Family Sharing rather than paying for it.
    public var isFamilyShared: Bool
    /// Goes up by one with every save. Save a changed record only where the stored revision is
    /// the one the engine read.
    public var revision: Int
    public var updatedAt: Date

    public init(
        transactionID: String,
        productID: String,
        store: Store,
        accountID: String? = nil,
        orderID: String? = nil,
        quantity: Int,
        purchasedAt: Date,
        expiresAt: Date? = nil,
        revokedQuantity: Int = 0,
        revokedAt: Date? = nil,
        storeRevokedAt: Date? = nil,
        reversedThrough: Date? = nil,
        reinstatedAt: Date? = nil,
        isTest: Bool = false,
        isFamilyShared: Bool = false,
        revision: Int = 1,
        updatedAt: Date
    ) {
        self.transactionID = transactionID
        self.productID = productID
        self.store = store
        self.accountID = accountID
        self.orderID = orderID
        self.quantity = quantity
        self.purchasedAt = purchasedAt
        self.expiresAt = expiresAt
        self.revokedQuantity = revokedQuantity
        self.revokedAt = revokedAt
        self.storeRevokedAt = storeRevokedAt
        self.reversedThrough = reversedThrough
        self.reinstatedAt = reinstatedAt
        self.isTest = isTest
        self.isFamilyShared = isFamilyShared
        self.revision = revision
        self.updatedAt = updatedAt
    }

    /// Reads a stored record. A field this version added is filled with its default when a
    /// stored row does not have it, so rows saved by an earlier version keep decoding.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            transactionID: try container.decode(String.self, forKey: .transactionID),
            productID: try container.decode(String.self, forKey: .productID),
            store: try container.decode(Store.self, forKey: .store),
            accountID: try container.decodeIfPresent(String.self, forKey: .accountID),
            orderID: try container.decodeIfPresent(String.self, forKey: .orderID),
            quantity: try container.decode(Int.self, forKey: .quantity),
            purchasedAt: try container.decode(Date.self, forKey: .purchasedAt),
            expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt),
            revokedQuantity: try container.decodeIfPresent(Int.self, forKey: .revokedQuantity) ?? 0,
            revokedAt: try container.decodeIfPresent(Date.self, forKey: .revokedAt),
            storeRevokedAt: try container.decodeIfPresent(Date.self, forKey: .storeRevokedAt),
            reversedThrough: try container.decodeIfPresent(Date.self, forKey: .reversedThrough),
            reinstatedAt: try container.decodeIfPresent(Date.self, forKey: .reinstatedAt),
            isTest: try container.decodeIfPresent(Bool.self, forKey: .isTest) ?? false,
            isFamilyShared: try container.decodeIfPresent(Bool.self, forKey: .isFamilyShared) ?? false,
            revision: try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1,
            updatedAt: try container.decode(Date.self, forKey: .updatedAt))
    }

    /// Every unit is refunded or revoked.
    public var isRevoked: Bool { revokedQuantity >= quantity }

    /// The units the buyer still holds.
    public var remainingQuantity: Int { max(0, quantity - revokedQuantity) }

    /// Whether the purchase gives access at `date`: not fully refunded, and not past its end.
    public func isActive(at date: Date) -> Bool {
        guard !isRevoked else { return false }
        guard let expiresAt else { return true }
        return date < expiresAt
    }
}
