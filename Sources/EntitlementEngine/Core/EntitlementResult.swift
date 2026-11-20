//
//  EntitlementResult.swift
//  iap-entitlement-engine
//

import Foundation

/// What one process call did.
///
/// A process call throws only when nothing was saved. Everything after the save, including a
/// push that failed, is reported here. A later release can add fields.
public struct EntitlementResult: Sendable {
    /// The order as it now stands. It equals the order passed in when nothing changed.
    public let order: Order
    /// Whether the delegate saved `order`.
    public let didSave: Bool
    /// When the access this call found ends: the paid period, or the grace period while the
    /// store keeps access open.
    ///
    /// `nil` means this call found no end date, which happens in two ways. Tell them apart by
    /// ``order``: if it is not subscribed, access has ended, so clear the date you stored. If it
    /// is still subscribed, the call concluded nothing, so keep the date you stored.
    public let accessExpiresAt: Date?
    /// The message that was due, whether or not it went out.
    public let notification: EntitlementNotification?
    /// Why the message did not go out. `nil` when it was sent, or when none was due.
    public let pushFailure: (any Error)?

    /// The engine builds its own results. This is for a test double of the engine.
    public init(
        order: Order,
        didSave: Bool = false,
        accessExpiresAt: Date? = nil,
        notification: EntitlementNotification? = nil,
        pushFailure: (any Error)? = nil
    ) {
        self.order = order
        self.didSave = didSave
        self.accessExpiresAt = accessExpiresAt
        self.notification = notification
        self.pushFailure = pushFailure
    }
}
