//
//  AppStoreSignedDataAdapter.swift
//  iap-entitlement-engine
//

import Foundation

/// Reduces App Store Server API and Notifications V2 data to a ``SubscriptionSnapshot``.
///
/// Mirrors ``AppleReceiptAdapter`` so an app migrating off `verifyReceipt` keeps the same behavior.
enum AppStoreSignedDataAdapter {
    private static let autoRenewOn: Int32 = 1
    private static let revokedForAppIssue: Int32 = 1
    private static let introductoryOffer: Int32 = 1
    private static let freeTrialDiscount = "FREE_TRIAL"

    static func snapshot(
        transaction: AppStoreTransaction,
        renewalInfo renewal: AppStoreRenewalInfo,
        now: Date
    ) throws -> SubscriptionSnapshot {
        guard let productID = transaction.productId, !productID.isEmpty else {
            return SubscriptionSnapshot(
                productID: "", lifecycle: .notSubscribed, expiresAt: nil, autoRenewEnabled: false, offer: .none)
        }
        if let original = transaction.originalTransactionId, let renewing = renewal.originalTransactionId,
           original != renewing {
            throw EntitlementError.transactionMismatch
        }

        let autoRenewEnabled = renewal.autoRenewStatus == autoRenewOn
        let offer = offer(of: transaction)

        func make(_ lifecycle: SubscriptionSnapshot.Lifecycle, expiresAt: Date?) -> SubscriptionSnapshot {
            SubscriptionSnapshot(
                productID: productID,
                lifecycle: lifecycle,
                expiresAt: expiresAt,
                autoRenewEnabled: autoRenewEnabled,
                offer: offer)
        }

        // An upgraded transaction also carries a revocation date, so this has to come first.
        if transaction.isUpgraded == true {
            return make(.upgraded, expiresAt: nil)
        }
        if transaction.revocationDate != nil {
            return make(.revoked(transaction.revocationReason == revokedForAppIssue ? .appIssue : .other), expiresAt: nil)
        }

        guard let expiresAt = transaction.expiresDate else {
            throw EntitlementError.invalidDate(field: "expiresDate")
        }
        if expiresAt <= now {
            let grace = renewal.gracePeriodExpiresDate
            // Apple also retries during a grace period, and access continues until that ends.
            if renewal.isInBillingRetryPeriod == true, (grace ?? .distantPast) <= now {
                return make(.suspended(.billing), expiresAt: expiresAt)
            }
            if let grace {
                return make(.gracePeriod, expiresAt: grace)
            }
        }
        return make(.active, expiresAt: expiresAt)
    }

    private static func offer(of transaction: AppStoreTransaction) -> SubscriptionSnapshot.Offer {
        if transaction.offerDiscountType == freeTrialDiscount {
            return .trial
        }
        return transaction.offerType == introductoryOffer ? .introductory : .none
    }
}
