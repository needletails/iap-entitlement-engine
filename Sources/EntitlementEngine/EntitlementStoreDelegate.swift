//
//  EntitlementStoreDelegate.swift
//  iap-entitlement-engine
//
//  Created by Cole M on 10/13/24.
//

import Foundation

public protocol EntitlementStoreDelegate: Sendable {
    func updateOrder(new Order: Order, id: UUID) async throws
}
