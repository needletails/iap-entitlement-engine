//
//  EntitlementStoreDelegate.swift
//  iap-entitlement-engine
//

/// Saves orders for the engine.
public protocol EntitlementStoreDelegate: Sendable {
    /// Saves `order` in place of `previous`.
    ///
    /// Called only when the engine changed the order, and before any push. If this throws,
    /// nothing is pushed and the process call rethrows your error.
    ///
    /// `previous` is the order the caller passed to the engine. Two events for one order can
    /// arrive together, so compare `previous` with what is stored and throw if they differ,
    /// rather than let the later write undo the earlier one.
    func updateOrder(_ order: Order, replacing previous: Order) async throws
}
