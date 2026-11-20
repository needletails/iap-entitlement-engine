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
            // Only a value with nothing in it means Apple returned no transactions. One that
            // lost its product on the way must not end a paid subscription.
            guard transaction == AppStoreTransaction() else {
                throw EntitlementError.missingProductID
            }
            return SubscriptionSnapshot(
                productID: "", lifecycle: .notSubscribed, expiresAt: nil, autoRenewEnabled: false, offer: .none)
        }
        if let original = transaction.originalTransactionId, let renewing = renewal.originalTransactionId,
           original != renewing {
            throw EntitlementError.transactionMismatch
        }

        // Only Apple saying "off" earns the expiry warning. Having no status is not that.
        let autoRenewEnabled = renewal.autoRenewStatus.map { $0 == autoRenewOn } ?? true
        let offer = offer(of: transaction)

        func make(
            _ lifecycle: SubscriptionSnapshot.Lifecycle, expiresAt: Date?, earlierPeriod: Bool = false
        ) -> SubscriptionSnapshot {
            SubscriptionSnapshot(
                productID: productID,
                lifecycle: lifecycle,
                expiresAt: expiresAt,
                autoRenewEnabled: autoRenewEnabled,
                offer: offer,
                isEarlierPeriod: earlierPeriod)
        }

        // An upgraded transaction also carries a revocation date, so this has to come first.
        if transaction.isUpgraded == true {
            return make(.upgraded, expiresAt: nil)
        }
        /// What a period that has ended leaves behind.
        ///
        /// - Parameter earlierPeriod: The transaction is not the subscription's latest purchase,
        ///   so its product may no longer be the one the subscriber is on.
        func standing(lapsedAt expiresAt: Date, earlierPeriod: Bool) throws -> SubscriptionSnapshot {
            // An empty value means the caller passed none, and a lapsed period then looks the
            // same with or without a grace period.
            guard renewal != AppStoreRenewalInfo() else {
                throw EntitlementError.missingRenewalInfo
            }
            let grace = renewal.gracePeriodExpiresDate
            let graceIsRunning = (grace ?? .distantPast) > now
            // Apple also retries during a grace period, and access continues until that ends.
            if renewal.isInBillingRetryPeriod == true, !graceIsRunning {
                return make(.suspended(.billing), expiresAt: expiresAt)
            }
            if let grace, graceIsRunning {
                return make(.gracePeriod, expiresAt: grace, earlierPeriod: earlierPeriod)
            }
            // Apple names when the subscription's most recent purchase expires. While that is
            // still ahead, this transaction is an earlier period, such as the one a declined
            // refund is about, and says nothing about access now. A grace date left over from
            // an earlier failure does not change that.
            if let latestExpiry = renewal.renewalDate, latestExpiry > now {
                return make(.pending, expiresAt: nil)
            }
            if let grace {
                return make(.gracePeriod, expiresAt: grace)
            }
            return make(.active, expiresAt: expiresAt)
        }

        if let revokedAt = transaction.revocationDate {
            // A refund ends access when it is for the subscription's most recent purchase. Apple
            // names that purchase's expiry in renewalDate. Without it, every revocation ends access.
            if let expiresAt = transaction.expiresDate, expiresAt <= revokedAt,
               let latestExpiry = renewal.renewalDate, latestExpiry > expiresAt {
                // The refunded period is an earlier one, so the subscription stands as its
                // latest purchase left it: untouched while that runs, and ended once it has not.
                return try standing(lapsedAt: latestExpiry, earlierPeriod: true)
            }
            return make(.revoked(transaction.revocationReason == revokedForAppIssue ? .appIssue : .other), expiresAt: nil)
        }

        guard let expiresAt = transaction.expiresDate else {
            throw EntitlementError.invalidDate(field: "expiresDate")
        }
        guard expiresAt <= now else {
            return make(.active, expiresAt: expiresAt)
        }
        return try standing(lapsedAt: expiresAt, earlierPeriod: renewal.renewalDate.map { $0 > expiresAt } ?? false)
    }

    private static func offer(of transaction: AppStoreTransaction) -> SubscriptionSnapshot.Offer {
        if transaction.offerDiscountType == freeTrialDiscount {
            return .trial
        }
        return transaction.offerType == introductoryOffer ? .introductory : .none
    }
}
