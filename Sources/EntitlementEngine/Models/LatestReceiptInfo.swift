//
//  LatestReceiptInfo.swift
//  
//
//  Created by Cole M on 5/30/23.
//

import Foundation

public struct LatestReceiptInfo: Codable, Sendable {
    public var quantity: String
    public var productId: String
    public var transactionId: String
    public var originalTransactionId: String
    public var purchaseDate: String
    public var purchaseDateMs: String
    public var purchaseDatePst: String
    public var originalPurchaseDate: String
    public var originalPurchaseDateMs: String
    public var originalPurchaseDatePst: String
    public var expiresDate: String
    public var expiresDateMs: String
    public var expiresDatePst: String
    public var webOrderLineItemId: String
    public var isTrialPeriod: String
    public var isInIntroOfferPeriod: String
    public var subscriptionGroupIdentifier: String
    public var cancellationDate: String?
    public var cancellationDateMs: String?
    public var cancellationDatePst: String?
    public var cancellationReason: String?
    public var isUpgraded: String?
    public var offerCodeRefName: String?
    public var promotionalOfferId: String?
    
    public init(quantity: String = "",
                productId: String = "",
                transactionId: String = "",
                originalTransactionId: String = "",
                purchaseDate: String = "",
                purchaseDateMs: String = "",
                purchaseDatePst: String = "",
                originalPurchaseDate: String = "",
                originalPurchaseDateMs: String = "",
                originalPurchaseDatePst: String = "",
                expiresDate: String = "",
                expiresDateMs: String = "",
                expiresDatePst: String = "",
                webOrderLineItemId: String = "",
                isTrialPeriod: String = "",
                isInIntroOfferPeriod: String = "",
                subscriptionGroupIdentifier: String = "",
                cancellationDate: String? = nil,
                cancellationDateMs: String? = nil,
                cancellationDatePst: String? = nil,
                cancellationReason: String? = nil,
                isUpgraded: String? = nil,
                offerCodeRefName: String? = nil,
                promotionalOfferId: String? = nil) {
        self.quantity = quantity
        self.productId = productId
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.purchaseDate = purchaseDate
        self.purchaseDateMs = purchaseDateMs
        self.purchaseDatePst = purchaseDatePst
        self.originalPurchaseDate = originalPurchaseDate
        self.originalPurchaseDateMs = originalPurchaseDateMs
        self.originalPurchaseDatePst = originalPurchaseDatePst
        self.expiresDate = expiresDate
        self.expiresDateMs = expiresDateMs
        self.expiresDatePst = expiresDatePst
        self.webOrderLineItemId = webOrderLineItemId
        self.isTrialPeriod = isTrialPeriod
        self.isInIntroOfferPeriod = isInIntroOfferPeriod
        self.subscriptionGroupIdentifier = subscriptionGroupIdentifier
        self.cancellationDate = cancellationDate
        self.cancellationDateMs = cancellationDateMs
        self.cancellationDatePst = cancellationDatePst
        self.cancellationReason = cancellationReason
        self.isUpgraded = isUpgraded
        self.offerCodeRefName = offerCodeRefName
        self.promotionalOfferId = promotionalOfferId
    }
    
    private enum CodingKeys: String, CodingKey {
        case quantity
        case productId = "product_id"
        case transactionId = "transaction_id"
        case originalTransactionId = "original_transaction_id"
        case purchaseDate = "purchase_date"
        case purchaseDateMs = "purchase_date_ms"
        case purchaseDatePst = "purchase_date_pst"
        case originalPurchaseDate = "original_purchase_date"
        case originalPurchaseDateMs = "original_purchase_date_ms"
        case originalPurchaseDatePst = "original_purchase_date_pst"
        case expiresDate = "expires_date"
        case expiresDateMs = "expires_date_ms"
        case expiresDatePst = "expires_date_pst"
        case webOrderLineItemId = "web_order_line_item_id"
        case isTrialPeriod = "is_trial_period"
        case isInIntroOfferPeriod = "is_in_intro_offer_period"
        case subscriptionGroupIdentifier = "subscription_group_identifier"
        case cancellationDate = "cancellation_date"
        case cancellationDateMs = "cancellation_date_ms"
        case cancellationDatePst = "cancellation_date_pst"
        case cancellationReason = "cancellation_reason"
        case isUpgraded = "is_upgraded"
        case offerCodeRefName = "offer_code_ref_name"
        case promotionalOfferId = "promotional_offer_id"
    }
}
