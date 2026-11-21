//
//  PurchaseStoreDelegate.swift
//  iap-entitlement-engine
//

/// Stores one-time purchases for the ``PurchaseEngine``.
public protocol PurchaseStoreDelegate: Sendable {
    /// The record saved for this transaction of this store, or `nil` if there is none.
    func purchase(transactionID: String, store: PurchaseRecord.Store) async throws -> PurchaseRecord?

    /// Saves `record` in place of `previous`, and applies `quantityChange` to what the buyer
    /// holds.
    ///
    /// Called only when the engine changed something, and before any push. If this throws,
    /// nothing is pushed and the process call rethrows your error.
    ///
    /// - Parameters:
    ///   - record: The purchase as it now stands.
    ///   - previous: What the engine read, or `nil` when it found no record.
    ///   - quantityChange: The units to add to what the buyer holds, or to take away when
    ///     negative. It is zero when only the record's bookkeeping changed. The engine reports
    ///     each change once, so apply it here, in the same database transaction as the record.
    ///     If the record is saved and the change is applied afterwards, a crash in between
    ///     loses a paid purchase or keeps a refunded one.
    ///
    /// Two events for one purchase can arrive together, so the save has to be conditional
    /// both ways, and has to throw when its condition does not hold:
    /// - A new record: insert it only if none exists. A unique key on the store and the
    ///   transaction ID does this.
    /// - A changed record: update it only where the stored ``PurchaseRecord/revision`` equals
    ///   `previous.revision`.
    ///
    /// Without the first check one purchase can be granted twice. Without the second, one
    /// refund can be taken back twice.
    func savePurchase(
        _ record: PurchaseRecord, replacing previous: PurchaseRecord?, quantityChange: Int
    ) async throws
}
