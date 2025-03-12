//
//  Order.swift
//  
//
//  Created by Cole M on 5/30/23.
//

import Foundation

public struct Order: Codable, Sendable {
    
    public let id: UUID
    public var productName: String?
    public var imageString: String?
    public var currency: String?
    public var quantity: Int?
    public var price: Int?
    public var isPurchased: Bool?
    public var isSubscribed: Bool?
    public var orderDescription: String?
    public var createdAt: Date?
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
}
