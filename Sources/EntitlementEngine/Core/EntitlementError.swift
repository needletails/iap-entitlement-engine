//
//  EntitlementError.swift
//  iap-entitlement-engine
//

/// Thrown when a store payload cannot be trusted. Nothing is persisted or pushed when one of these is thrown.
public enum EntitlementError: Error, Sendable, Equatable {
    /// The `orderId` passed to the engine is not a UUID.
    case invalidOrderID
    /// A required date is missing or malformed. Access is never granted on a date that cannot be read.
    case invalidDate(field: String)
    /// The Apple receipt or transaction and its renewal info belong to different subscriptions.
    case transactionMismatch
    /// Google returned a subscription state this version of the SDK does not know about.
    case unsupportedState(String)
    /// `processReceipt` was called on an engine created without an APNs topic and device token.
    case missingAPNsConfiguration
}
