//
//  ProductCatalog.swift
//  iap-entitlement-engine
//

/// The store identifiers this app sells. Anything else is never entitled.
public struct ProductCatalog: Sendable, Equatable {
    public let weekly: String
    public let monthly: String
    public let yearly: String

    public init(weekly: String, monthly: String, yearly: String) {
        self.weekly = weekly
        self.monthly = monthly
        self.yearly = yearly
    }

    func contains(_ productID: String) -> Bool {
        productID == weekly || productID == monthly || productID == yearly
    }

    func activeNotification(for productID: String) -> EntitlementNotification {
        switch productID {
        case weekly: .weeklyActive
        case yearly: .yearlyActive
        default: .monthlyActive
        }
    }
}
