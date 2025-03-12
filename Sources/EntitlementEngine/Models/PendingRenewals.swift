//
//  PendingRenewalInfo.swift
//  
//
//  Created by Cole M on 5/30/23.
//

import Foundation

public struct PendingRenewalInfo: Codable, Sendable {
    
    public var autoRenewProductId: String
    public var originalTransactionId: String
    public var autoRenewStatus: String
    public var expirationIntent: String?
    public var gracePeriodExpiresDate: String?
    public var gracePeriodExpiresDateMs: String?
    public var gracePeriodExpiresDatePst: String?
    public var isInBillingRetryPeriod: String?
    public var offerCodeRefName: String?
    public var priceConsentStatus: String?
    public var productId: String?
    
    public init(autoRenewProductId: String = "",
                originalTransactionId: String = "",
                autoRenewStatus: String = "",
                expirationIntent: String? = nil,
                gracePeriodExpiresDate: String? = nil,
                gracePeriodExpiresDateMs: String? = nil,
                gracePeriodExpiresDatePst: String? = nil,
                isInBillingRetryPeriod: String? = nil,
                offerCodeRefName: String? = nil,
                priceConsentStatus: String? = nil,
                productId: String? = nil) {
        self.autoRenewProductId = autoRenewProductId
        self.originalTransactionId = originalTransactionId
        self.autoRenewStatus = autoRenewStatus
        self.expirationIntent = expirationIntent
        self.gracePeriodExpiresDate = gracePeriodExpiresDate
        self.gracePeriodExpiresDateMs = gracePeriodExpiresDateMs
        self.gracePeriodExpiresDatePst = gracePeriodExpiresDatePst
        self.isInBillingRetryPeriod = isInBillingRetryPeriod
        self.offerCodeRefName = offerCodeRefName
        self.priceConsentStatus = priceConsentStatus
        self.productId = productId
    }
    
    private enum CodingKeys: String, CodingKey {
        case autoRenewProductId = "auto_renew_product_id"
        case originalTransactionId = "original_transaction_id"
        case autoRenewStatus = "auto_renew_status"
        case expirationIntent = "expiration_intent"
        case gracePeriodExpiresDate = "grace_period_expires_date"
        case gracePeriodExpiresDateMs = "grace_period_expires_date_ms"
        case gracePeriodExpiresDatePst = "grace_period_expires_date_pst"
        case isInBillingRetryPeriod = "is_in_billing_retry_period"
        case offerCodeRefName = "offer_code_ref_name"
        case priceConsentStatus = "price_consent_status"
        case productId = "product_id"
    }
}
