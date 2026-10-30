//
//  AppStoreSignedData.swift
//  iap-entitlement-engine
//

import Foundation

/// The fields the engine reads from a verified `JWSTransactionDecodedPayload`.
///
/// Decodes the payload JSON directly, or map them from `AppStoreServerLibrary`'s type of the same
/// name. Dates are read as Apple's milliseconds whatever date strategy the decoder is set to.
public struct AppStoreTransaction: Decodable, Sendable, Equatable {
    public var productId: String?
    public var originalTransactionId: String?
    public var expiresDate: Date?
    public var isUpgraded: Bool?
    public var revocationDate: Date?
    public var revocationReason: Int32?
    public var offerType: Int32?
    public var offerDiscountType: String?

    public init(
        productId: String? = nil,
        originalTransactionId: String? = nil,
        expiresDate: Date? = nil,
        isUpgraded: Bool? = nil,
        revocationDate: Date? = nil,
        revocationReason: Int32? = nil,
        offerType: Int32? = nil,
        offerDiscountType: String? = nil
    ) {
        self.productId = productId
        self.originalTransactionId = originalTransactionId
        self.expiresDate = expiresDate
        self.isUpgraded = isUpgraded
        self.revocationDate = revocationDate
        self.revocationReason = revocationReason
        self.offerType = offerType
        self.offerDiscountType = offerDiscountType
    }

    private enum CodingKeys: String, CodingKey {
        case productId, originalTransactionId, expiresDate, isUpgraded
        case revocationDate, revocationReason, offerType, offerDiscountType
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            productId: try container.decodeIfPresent(String.self, forKey: .productId),
            originalTransactionId: try container.decodeIfPresent(String.self, forKey: .originalTransactionId),
            expiresDate: try container.decodeIfPresent(Int64.self, forKey: .expiresDate).map(Date.init(milliseconds:)),
            isUpgraded: try container.decodeIfPresent(Bool.self, forKey: .isUpgraded),
            revocationDate: try container.decodeIfPresent(Int64.self, forKey: .revocationDate).map(Date.init(milliseconds:)),
            revocationReason: try container.decodeIfPresent(Int32.self, forKey: .revocationReason),
            offerType: try container.decodeIfPresent(Int32.self, forKey: .offerType),
            offerDiscountType: try container.decodeIfPresent(String.self, forKey: .offerDiscountType))
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

    public init(
        originalTransactionId: String? = nil,
        autoRenewStatus: Int32? = nil,
        gracePeriodExpiresDate: Date? = nil,
        isInBillingRetryPeriod: Bool? = nil
    ) {
        self.originalTransactionId = originalTransactionId
        self.autoRenewStatus = autoRenewStatus
        self.gracePeriodExpiresDate = gracePeriodExpiresDate
        self.isInBillingRetryPeriod = isInBillingRetryPeriod
    }

    private enum CodingKeys: String, CodingKey {
        case originalTransactionId, autoRenewStatus, gracePeriodExpiresDate, isInBillingRetryPeriod
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            originalTransactionId: try container.decodeIfPresent(String.self, forKey: .originalTransactionId),
            autoRenewStatus: try container.decodeIfPresent(Int32.self, forKey: .autoRenewStatus),
            gracePeriodExpiresDate: try container.decodeIfPresent(Int64.self, forKey: .gracePeriodExpiresDate)
                .map(Date.init(milliseconds:)),
            isInBillingRetryPeriod: try container.decodeIfPresent(Bool.self, forKey: .isInBillingRetryPeriod))
    }
}
