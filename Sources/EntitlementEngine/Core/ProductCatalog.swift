//
//  ProductCatalog.swift
//  iap-entitlement-engine
//

/// The store identifiers this app sells. Anything else never starts a subscription.
struct ProductCatalog: Sendable, Equatable {
    let weekly: String
    let monthly: String
    let yearly: String

    /// An empty slot is a plan the app does not sell, so an empty ID is never a product.
    func contains(_ productID: String) -> Bool {
        !productID.isEmpty && (productID == weekly || productID == monthly || productID == yearly)
    }

    func activeNotification(for productID: String) -> EntitlementNotification {
        switch productID {
        case weekly: .weeklyActive
        case yearly: .yearlyActive
        default: .monthlyActive
        }
    }
}
