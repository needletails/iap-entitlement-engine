//
//  IAPPayload.swift
//  iap-entitlement-engine
//
//  Created by Cole M on 10/13/24.
//

import Foundation

/// The copy of one message, and optional data for the app.
///
/// APNs carries it at the root of the payload beside `aps`. FCM carries `data` base64-encoded as
/// the data field `payload`, and has no subtitle, so the subtitle is folded into the body.
public struct IAPPayload: Codable, Sendable, Equatable {
    
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
