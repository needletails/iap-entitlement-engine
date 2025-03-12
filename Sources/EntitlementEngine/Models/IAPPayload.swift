//
//  IAPPayload.swift
//  iap-entitlement-engine
//
//  Created by Cole M on 10/13/24.
//

import Foundation

public struct IAPPayload: Codable, Sendable {
    
    public let title: String
    public let subtitle: String
    public let body: String
    public let data: Data?
    
    public init(
        title: String,
        subtitle: String,
        body: String,
        data: Data? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.data = data
    }
}
