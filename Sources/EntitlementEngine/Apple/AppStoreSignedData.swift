//
//  AppStoreSignedData.swift
//  iap-entitlement-engine
//

import Foundation

/// The fields the engine reads from a verified `JWSTransactionDecodedPayload`.
///
/// Decodes the payload JSON directly, or map them from `AppStoreServerLibrary`'s type of the same
/// name. Dates are read as Apple's milliseconds whatever date strategy the decoder is set to.
///
/// Decoding throws on JSON with no `productId`, which Apple always sends. Only a value with
/// nothing set means "no subscription". One with other fields but no product throws
/// `missingProductID`, so that a lost product can never end a paid subscription.
public struct AppStoreTransaction: Decodable, Sendable, Equatable {
    public var productId: String?
    public var originalTransactionId: String?
    public var expiresDate: Date?
    public var isUpgraded: Bool?
    public var revocationDate: Date?
    public var revocationReason: Int32?
    public var offerType: Int32?
    public var offerDiscountType: String?
    /// Unique for each transaction. A one-time purchase is recorded under its original
    /// transaction ID, which is this value for the purchase itself.
    public var transactionId: String?
    /// Apple's name for the kind of product, such as `Consumable`.
    public var type: String?
    /// How many units of a consumable were bought.
    public var quantity: Int32?
    public var purchaseDate: Date?
    /// The UUID your app attached to the purchase to say whose it is.
    public var appAccountToken: String?
    /// `PURCHASED`, or `FAMILY_SHARED` for a purchase shared with the buyer's family.
    public var inAppOwnershipType: String?
    /// `Production`, or `Sandbox`, `Xcode` or `LocalTesting` for a test purchase.
    public var environment: String?
    /// Why access was revoked: `REFUND_FULL`, `REFUND_PRORATED`, `FAMILY_REVOKE` or
    /// `ASSIGNMENT_REVOKE`.
    public var revocationType: String?
    /// How much of a prorated refund was refunded, in thousandths of a percent.
    public var revocationPercentage: Int64?
    /// When Apple signed this transaction.
    public var signedDate: Date?

    public init(
        productId: String? = nil,
        originalTransactionId: String? = nil,
        expiresDate: Date? = nil,
        isUpgraded: Bool? = nil,
        revocationDate: Date? = nil,
        revocationReason: Int32? = nil,
        offerType: Int32? = nil,
        offerDiscountType: String? = nil,
        transactionId: String? = nil,
        type: String? = nil,
        quantity: Int32? = nil,
        purchaseDate: Date? = nil,
        appAccountToken: String? = nil,
        inAppOwnershipType: String? = nil,
        environment: String? = nil,
        revocationType: String? = nil,
        revocationPercentage: Int64? = nil,
        signedDate: Date? = nil
    ) {
        self.productId = productId
        self.originalTransactionId = originalTransactionId
        self.expiresDate = expiresDate
        self.isUpgraded = isUpgraded
        self.revocationDate = revocationDate
        self.revocationReason = revocationReason
        self.offerType = offerType
        self.offerDiscountType = offerDiscountType
        self.transactionId = transactionId
        self.type = type
        self.quantity = quantity
        self.purchaseDate = purchaseDate
        self.appAccountToken = appAccountToken
        self.inAppOwnershipType = inAppOwnershipType
        self.environment = environment
        self.revocationType = revocationType
        self.revocationPercentage = revocationPercentage
        self.signedDate = signedDate
    }

    private enum CodingKeys: String, CodingKey {
        case productId, originalTransactionId, expiresDate, isUpgraded
        case revocationDate, revocationReason, offerType, offerDiscountType
        case transactionId, type, quantity, purchaseDate, appAccountToken, inAppOwnershipType, environment
        case revocationType, revocationPercentage, signedDate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            productId: try container.decode(String.self, forKey: .productId),
            originalTransactionId: try container.decodeIfPresent(String.self, forKey: .originalTransactionId),
            expiresDate: try container.decodeIfPresent(Int64.self, forKey: .expiresDate).map(Date.init(milliseconds:)),
            isUpgraded: try container.decodeIfPresent(Bool.self, forKey: .isUpgraded),
            revocationDate: try container.decodeIfPresent(Int64.self, forKey: .revocationDate).map(Date.init(milliseconds:)),
            revocationReason: try container.decodeIfPresent(Int32.self, forKey: .revocationReason),
            offerType: try container.decodeIfPresent(Int32.self, forKey: .offerType),
            offerDiscountType: try container.decodeIfPresent(String.self, forKey: .offerDiscountType),
            // Subscriptions never read the fields below, so one that has an unexpected shape
            // is left out rather than failing a subscription event.
            transactionId: try? container.decodeIfPresent(String.self, forKey: .transactionId),
            type: try? container.decodeIfPresent(String.self, forKey: .type),
            quantity: try? container.decodeIfPresent(Int32.self, forKey: .quantity),
            purchaseDate: (try? container.decodeIfPresent(Int64.self, forKey: .purchaseDate)).map(Date.init(milliseconds:)),
            appAccountToken: try? container.decodeIfPresent(String.self, forKey: .appAccountToken),
            inAppOwnershipType: try? container.decodeIfPresent(String.self, forKey: .inAppOwnershipType),
            environment: try? container.decodeIfPresent(String.self, forKey: .environment),
            revocationType: try? container.decodeIfPresent(String.self, forKey: .revocationType),
            revocationPercentage: try? container.decodeIfPresent(Int64.self, forKey: .revocationPercentage),
            signedDate: (try? container.decodeIfPresent(Int64.self, forKey: .signedDate)).map(Date.init(milliseconds:)))
    }
}

/// The fields the engine reads from a verified `JWSRenewalInfoDecodedPayload`.
///
/// Decodes the payload JSON directly, or map them from `AppStoreServerLibrary`'s type of the same
/// name. Dates are read as Apple's milliseconds whatever date strategy the decoder is set to.
public struct AppStoreRenewalInfo: Decodable, Sendable, Equatable {
    public var originalTransactionId: String?
    public var autoRenewStatus: Int32?
    public var gracePeriodExpiresDate: Date?
    public var isInBillingRetryPeriod: Bool?
    /// When the subscription's most recent purchase expires.
    public var renewalDate: Date?

    public init(
        originalTransactionId: String? = nil,
        autoRenewStatus: Int32? = nil,
        gracePeriodExpiresDate: Date? = nil,
        isInBillingRetryPeriod: Bool? = nil,
        renewalDate: Date? = nil
    ) {
        self.originalTransactionId = originalTransactionId
        self.autoRenewStatus = autoRenewStatus
        self.gracePeriodExpiresDate = gracePeriodExpiresDate
        self.isInBillingRetryPeriod = isInBillingRetryPeriod
        self.renewalDate = renewalDate
    }

    private enum CodingKeys: String, CodingKey {
        case originalTransactionId, autoRenewStatus, gracePeriodExpiresDate, isInBillingRetryPeriod, renewalDate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            originalTransactionId: try container.decodeIfPresent(String.self, forKey: .originalTransactionId),
            autoRenewStatus: try container.decodeIfPresent(Int32.self, forKey: .autoRenewStatus),
            gracePeriodExpiresDate: try container.decodeIfPresent(Int64.self, forKey: .gracePeriodExpiresDate)
                .map(Date.init(milliseconds:)),
            isInBillingRetryPeriod: try container.decodeIfPresent(Bool.self, forKey: .isInBillingRetryPeriod),
            renewalDate: try container.decodeIfPresent(Int64.self, forKey: .renewalDate).map(Date.init(milliseconds:)))
    }
}
