//
//  EntitlementEngine.swift
//
//
//  Created by Cole M on 5/30/23.
//

import Foundation

/// Turns verified store data into an up-to-date ``Order`` and a user notification.
///
/// The engine trusts its inputs, so verify them with Apple or Google before calling it. It holds
/// no per-call state, so one engine can safely process many subscriptions at once.
///
/// A process call throws only when nothing was saved. Once the order is saved the call always
/// returns, and a push that failed is reported in ``EntitlementResult/pushFailure``.
public actor EntitlementEngine {

    /// How long APNs and FCM keep trying to deliver a message.
    private static let notificationLifetime: TimeInterval = 86_400

    private let storeDelegate: any EntitlementStoreDelegate
    private let messages: EntitlementMessages
    private let now: @Sendable () -> Date
    private let evaluator: EntitlementEvaluator

    /// - Parameters:
    ///   - storeDelegate: Saves an order when the engine changes it.
    ///   - weeklyProductID: The store product ID of the weekly plan, or the Play base plan ID.
    ///     Pass an empty string for a plan you do not sell. The same goes for the other two.
    ///   - retiredProductIDs: Products you no longer sell that still have subscribers. An order
    ///     on one of them keeps access either way. Listing it also lets that order get access
    ///     back after a billing retry, an account hold or a pause.
    ///   - messages: The copy for each notification.
    ///   - now: The clock. Keep the server's clock in sync, because an expiry is judged by it.
    public init(
        storeDelegate: any EntitlementStoreDelegate,
        weeklyProductID: String,
        monthlyProductID: String,
        yearlyProductID: String,
        retiredProductIDs: Set<String> = [],
        messages: EntitlementMessages = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeDelegate = storeDelegate
        self.messages = messages
        self.now = now
        self.evaluator = EntitlementEvaluator(
            catalog: ProductCatalog(weekly: weeklyProductID, monthly: monthlyProductID, yearly: yearlyProductID),
            retired: retiredProductIDs)
    }

    /// Applies a verified Apple receipt, then notifies the device through `notifier`.
    ///
    /// - Parameters:
    ///   - latestReceiptInfo: The subscription's most recent row of `latest_receipt_info`.
    ///   - pendingRenewalInfo: Its entry in `pending_renewal_info`.
    public func processReceipt(
        notifier: some EntitlementNotifier,
        order: Order,
        latestReceiptInfo: LatestReceiptInfo,
        pendingRenewalInfo: PendingRenewalInfo
    ) async throws -> EntitlementResult {
        guard evaluator.concerns(order, productID: latestReceiptInfo.productId) else {
            return unchanged(order)
        }
        let date = now()
        let snapshot = try AppleReceiptAdapter.snapshot(
            latestReceiptInfo: latestReceiptInfo,
            pendingRenewalInfo: pendingRenewalInfo,
            now: date)
        return try await apply(snapshot, order: order, notifier: notifier, now: date)
    }

    /// Applies verified App Store Server API or Notifications V2 data, then notifies the device
    /// through `notifier`.
    ///
    /// - Parameters:
    ///   - transaction: The decoded `signedTransactionInfo`. Verify its signature first.
    ///   - renewalInfo: The decoded `signedRenewalInfo`. Verify its signature first.
    public func processAppStoreTransaction(
        notifier: some EntitlementNotifier,
        order: Order,
        transaction: AppStoreTransaction,
        renewalInfo: AppStoreRenewalInfo
    ) async throws -> EntitlementResult {
        guard evaluator.concerns(order, productID: transaction.productId ?? "") else {
            return unchanged(order)
        }
        let date = now()
        let snapshot = try AppStoreSignedDataAdapter.snapshot(
            transaction: transaction,
            renewalInfo: renewalInfo,
            now: date)
        return try await apply(snapshot, order: order, notifier: notifier, now: date)
    }

    /// Applies a verified Google Play purchase, then notifies the device through `notifier`.
    ///
    /// - Parameters:
    ///   - purchase: The response of `purchases.subscriptionsv2.get`.
    ///   - isRevoked: Pass `true` for a `SUBSCRIPTION_REVOKED` real-time developer notification.
    public func processGooglePlayPurchase(
        notifier: some EntitlementNotifier,
        order: Order,
        purchase: GooglePlaySubscriptionPurchase,
        isRevoked: Bool = false
    ) async throws -> EntitlementResult {
        let date = now()
        let snapshot = try GooglePlayAdapter.snapshot(
            purchase: purchase,
            catalog: evaluator.catalog,
            held: order.productName,
            isRevoked: isRevoked,
            now: date)
        return try await apply(snapshot, order: order, notifier: notifier, now: date)
    }

    /// An event for a product that is neither sold nor held says nothing about this order, so it
    /// is not read any further. A one-time purchase has no expiry to read anyway.
    private func unchanged(_ order: Order) -> EntitlementResult {
        EntitlementResult(order: order, didSave: false, accessExpiresAt: nil, notification: nil, pushFailure: nil)
    }

    private func apply(
        _ snapshot: SubscriptionSnapshot,
        order: Order,
        notifier: some EntitlementNotifier,
        now date: Date
    ) async throws -> EntitlementResult {
        let decision = evaluator.evaluate(snapshot, order: order, now: date)

        var updated = order
        if let isSubscribed = decision.isSubscribed {
            updated.isSubscribed = isSubscribed
        }
        if let productName = decision.productName {
            updated.productName = productName
        }
        let changed = updated != order
        if changed {
            updated.updatedAt = date
            try await storeDelegate.updateOrder(updated, replacing: order)
        }

        // The order is saved, so from here a failure is reported rather than thrown. A caller
        // that answered its webhook with an error would have the store redeliver an event that
        // was already applied.
        var pushFailure: (any Error)?
        if let notification = decision.notification {
            do {
                try await notifier.send(
                    messages.payload(for: notification),
                    for: notification,
                    expiresAt: date.addingTimeInterval(Self.notificationLifetime))
            } catch {
                pushFailure = error
            }
        }
        return EntitlementResult(
            order: updated,
            didSave: changed,
            accessExpiresAt: decision.isSubscribed == true ? snapshot.expiresAt : nil,
            notification: decision.notification,
            pushFailure: pushFailure)
    }
}
