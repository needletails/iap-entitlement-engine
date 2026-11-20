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
            // Only an empty row means Apple returned no purchase. One that lost its product on
            // the way must not end a paid subscription.
            guard receipt.isEmpty else {
                throw EntitlementError.missingProductID
            }
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
            // An empty value means the caller passed none, and a lapsed period then looks the
            // same with or without a grace period.
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

private extension LatestReceiptInfo {
    /// Nothing is set. An optional field that is an empty string counts as not set, as it does
    /// everywhere else in this adapter.
    var isEmpty: Bool {
        var row = self
        if row.cancellationDate?.isEmpty == true { row.cancellationDate = nil }
        if row.cancellationDateMs?.isEmpty == true { row.cancellationDateMs = nil }
        if row.cancellationDatePst?.isEmpty == true { row.cancellationDatePst = nil }
        if row.cancellationReason?.isEmpty == true { row.cancellationReason = nil }
        if row.isUpgraded?.isEmpty == true { row.isUpgraded = nil }
        if row.offerCodeRefName?.isEmpty == true { row.offerCodeRefName = nil }
        if row.promotionalOfferId?.isEmpty == true { row.promotionalOfferId = nil }
        return row == LatestReceiptInfo()
    }
}

private extension PendingRenewalInfo {
    /// None of the fields the adapter reads is present.
    var isMissing: Bool {
        autoRenewStatus.isEmpty && originalTransactionId.isEmpty
            && (gracePeriodExpiresDateMs ?? "").isEmpty && (isInBillingRetryPeriod ?? "").isEmpty
    }
}
