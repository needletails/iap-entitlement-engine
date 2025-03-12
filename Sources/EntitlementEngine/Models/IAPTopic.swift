//
//  IAPTopic.swift
//  iap-entitlement-engine
//
//  Created by Cole M on 10/13/24.
//
import Foundation

public struct IAPTopic: Codable, Sendable {
    public let topic: String
    
    public init(topic: String) {
        self.topic = topic
    }
}
