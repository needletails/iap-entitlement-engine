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

        // Only Apple saying "off" earns the expiry warning. Having no status is not that.
        let autoRenewEnabled = renewal.autoRenewStatus.isEmpty || renewal.autoRenewStatus == "1"
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
        if expiresAt <= now {
            // Apple always fills renewal info in, so an empty one means the caller had none, and
            // a lapsed period then looks the same with or without a grace period.
            guard !renewal.isMissing else {
                throw EntitlementError.missingRenewalInfo
            }
            let grace = try renewal.gracePeriodExpiresDateMs
                .flatMap { $0.isEmpty ? nil : $0 }
                .map { try date($0, field: "grace_period_expires_date_ms") }
            // Apple also retries during a grace period, and access continues until that ends.
            if renewal.isInBillingRetryPeriod == "1", (grace ?? .distantPast) <= now {
                return make(.suspended(.billing), expiresAt: expiresAt)
            }
            if let grace {
                return make(.gracePeriod, expiresAt: grace)
            }
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

private extension PendingRenewalInfo {
    /// None of the fields the adapter reads is present.
    var isMissing: Bool {
        autoRenewStatus.isEmpty && originalTransactionId.isEmpty
            && (gracePeriodExpiresDateMs ?? "").isEmpty && (isInBillingRetryPeriod ?? "").isEmpty
    }
}
