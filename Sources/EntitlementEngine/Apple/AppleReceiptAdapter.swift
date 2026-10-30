//
//  AppleReceiptAdapter.swift
//  iap-entitlement-engine
//

import Foundation

/// Reduces an Apple receipt to a ``SubscriptionSnapshot``.
enum AppleReceiptAdapter {

    static func snapshot(
        latestReceiptInfo receipt: LatestReceiptInfo,
        pendingRenewalInfo renewal: PendingRenewalInfo,
        now: Date
    ) throws -> SubscriptionSnapshot {
        guard !receipt.productId.isEmpty else {
            return SubscriptionSnapshot(
                productID: "", lifecycle: .notSubscribed, expiresAt: nil, autoRenewEnabled: false, offer: .none)
        }
        if !receipt.originalTransactionId.isEmpty, !renewal.originalTransactionId.isEmpty,
           receipt.originalTransactionId != renewal.originalTransactionId {
            throw EntitlementError.transactionMismatch
        }

        let autoRenewEnabled = renewal.autoRenewStatus == "1"
        let offer: SubscriptionSnapshot.Offer =
            receipt.isTrialPeriod == "true" ? .trial
            : receipt.isInIntroOfferPeriod == "true" ? .introductory
            : .none

        func make(_ lifecycle: SubscriptionSnapshot.Lifecycle, expiresAt: Date?) -> SubscriptionSnapshot {
            SubscriptionSnapshot(
                productID: receipt.productId,
                lifecycle: lifecycle,
                expiresAt: expiresAt,
                autoRenewEnabled: autoRenewEnabled,
                offer: offer)
        }

        // An upgraded transaction also carries a cancellation date, so this has to come first.
        if receipt.isUpgraded == "true" {
            return make(.upgraded, expiresAt: nil)
        }
        if let cancellationDateMs = receipt.cancellationDateMs, !cancellationDateMs.isEmpty {
            _ = try date(cancellationDateMs, field: "cancellation_date_ms")
            return make(.revoked(receipt.cancellationReason == "1" ? .appIssue : .other), expiresAt: nil)
        }

        let expiresAt = try date(receipt.expiresDateMs, field: "expires_date_ms")
        if expiresAt <= now, let graceMs = renewal.gracePeriodExpiresDateMs, !graceMs.isEmpty {
            return make(.gracePeriod, expiresAt: try date(graceMs, field: "grace_period_expires_date_ms"))
        }
        return make(.active, expiresAt: expiresAt)
    }

    private static func date(_ milliseconds: String, field: String) throws -> Date {
        guard let value = Int64(milliseconds) else {
            throw EntitlementError.invalidDate(field: field)
        }
        return Date(milliseconds: value)
    }
}
