//
//  Order.swift
//  
//
//  Created by Cole M on 5/30/23.
//

import Foundation

/// The record of one account's subscription.
///
/// The engine reads and writes three fields: ``isSubscribed``, ``productName`` and
/// ``updatedAt``. The rest are yours. Keep one order per store for an account that can buy on
/// both, because each store only knows about its own subscription.
public struct Order: Codable, Sendable, Equatable {

    public let id: UUID
    /// The store product ID the subscription is on. The engine sets it when access starts or
    /// the product changes, and uses it to recognise the subscription's later events.
    public var productName: String?
    public var imageString: String?
    public var currency: String?
    public var quantity: Int?
    public var price: Int?
    public var isPurchased: Bool?
    /// Whether access is on. Set by the engine.
    public var isSubscribed: Bool?
    public var orderDescription: String?
    public var createdAt: Date?
    /// When the engine last changed this order.
    public var updatedAt: Date?
    public var deletedAt: Date?
    
    public init(
        id: UUID,
        productName: String? = "",
        imageString: String? = "",
        currency: String? = "",
        quantity: Int? = 0,
        price: Int? = 0,
        isPurchased: Bool? = false,
        isSubscribed: Bool? = false,
        orderDescription: String? = "",
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.productName = productName
        self.imageString = imageString
        self.currency = currency
        self.quantity = quantity
        self.price = price
        self.isPurchased = isPurchased
        self.isSubscribed = isSubscribed
        self.orderDescription = orderDescription
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Orders are persisted by callers, so these names are part of the stored format.
    private enum CodingKeys: String, CodingKey {
        case id, productName, imageString, currency, quantity, price, isPurchased, isSubscribed
        case orderDescription, createdAt, updatedAt, deletedAt
    }
}
