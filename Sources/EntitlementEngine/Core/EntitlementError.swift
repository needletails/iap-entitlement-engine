//
//  EntitlementError.swift
//  iap-entitlement-engine
//

/// Thrown when store data cannot be acted on. Nothing is saved or pushed when one of these is thrown.
///
/// A later release can add cases, so end a `switch` over it with `@unknown default`.
@nonexhaustive
public enum EntitlementError: Error, Sendable, Equatable {
    /// A required date is missing or malformed. Access is never granted on a date that cannot be read.
    case invalidDate(field: String)
    /// The Apple receipt or transaction and its renewal info belong to different subscriptions.
    case transactionMismatch
    /// The paid period has ended and the renewal info passed with it was empty, so a grace period
    /// cannot be ruled out. Pass the renewal info Apple returned and process again. If a
    /// `verifyReceipt` response truly has no entry for the subscription, Apple has stopped
    /// renewing it: pass a `PendingRenewalInfo` with its original transaction ID and
    /// `autoRenewStatus` "0".
    case missingRenewalInfo
    /// The Apple transaction or receipt row names no product but is not empty. Only an empty
    /// `AppStoreTransaction()` or `LatestReceiptInfo()` means that Apple returned no purchase.
    case missingProductID
    /// Google returned a subscription state this version of the SDK does not know about.
    case unsupportedState(String)
}
