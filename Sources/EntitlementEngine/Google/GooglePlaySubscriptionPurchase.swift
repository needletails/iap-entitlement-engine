//
//  GooglePlaySubscriptionPurchase.swift
//  iap-entitlement-engine
//

/// The `SubscriptionPurchaseV2` resource returned by `purchases.subscriptionsv2.get`.
///
/// Only the fields the engine uses are modelled. Unknown fields are ignored.
public struct GooglePlaySubscriptionPurchase: Codable, Sendable, Equatable {

    public struct Marker: Codable, Sendable, Equatable {
        public init() {}
    }

    public struct AutoRenewingPlan: Codable, Sendable, Equatable {
        public var autoRenewEnabled: Bool?

        public init(autoRenewEnabled: Bool? = nil) {
            self.autoRenewEnabled = autoRenewEnabled
        }
    }

    public struct OfferDetails: Codable, Sendable, Equatable {
        public var basePlanId: String?
        public var offerId: String?

        public init(basePlanId: String? = nil, offerId: String? = nil) {
            self.basePlanId = basePlanId
            self.offerId = offerId
        }
    }

    public struct OfferPhase: Codable, Sendable, Equatable {
        public var freeTrial: Marker?
        public var introductoryPrice: Marker?

        public init(freeTrial: Marker? = nil, introductoryPrice: Marker? = nil) {
            self.freeTrial = freeTrial
            self.introductoryPrice = introductoryPrice
        }
    }

    public struct LineItem: Codable, Sendable, Equatable {
        public var productId: String
        public var expiryTime: String?
        public var autoRenewingPlan: AutoRenewingPlan?
        public var offerDetails: OfferDetails?
        public var offerPhase: OfferPhase?

        public init(
            productId: String,
            expiryTime: String? = nil,
            autoRenewingPlan: AutoRenewingPlan? = nil,
            offerDetails: OfferDetails? = nil,
            offerPhase: OfferPhase? = nil
        ) {
            self.productId = productId
            self.expiryTime = expiryTime
            self.autoRenewingPlan = autoRenewingPlan
            self.offerDetails = offerDetails
            self.offerPhase = offerPhase
        }
    }

    public struct CanceledStateContext: Codable, Sendable, Equatable {
        public var replacementCancellation: Marker?

        public init(replacementCancellation: Marker? = nil) {
            self.replacementCancellation = replacementCancellation
        }
    }

    public var subscriptionState: String
    public var lineItems: [LineItem]?
    public var linkedPurchaseToken: String?
    public var acknowledgementState: String?
    public var canceledStateContext: CanceledStateContext?
    public var testPurchase: Marker?

    public init(
        subscriptionState: String,
        lineItems: [LineItem]? = nil,
        linkedPurchaseToken: String? = nil,
        acknowledgementState: String? = nil,
        canceledStateContext: CanceledStateContext? = nil,
        testPurchase: Marker? = nil
    ) {
        self.subscriptionState = subscriptionState
        self.lineItems = lineItems
        self.linkedPurchaseToken = linkedPurchaseToken
        self.acknowledgementState = acknowledgementState
        self.canceledStateContext = canceledStateContext
        self.testPurchase = testPurchase
    }

    /// New purchases that are not acknowledged within three days are refunded by Google.
    public var needsAcknowledgement: Bool {
        acknowledgementState == "ACKNOWLEDGEMENT_STATE_PENDING"
    }

    public var isTestPurchase: Bool {
        testPurchase != nil
    }
}
