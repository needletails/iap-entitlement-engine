//
//  EntitlementEngine.swift
//
//
//  Created by Cole M on 5/30/23.
//

import APNSCore
import Foundation
import HTTPTypes
import NeedleTailLogger

/// Turns verified store data into an up-to-date ``Order`` and a user notification.
///
/// The engine trusts its inputs, so verify them with Apple or Google before calling it. Holds no
/// per-call state, so one engine can safely process many subscriptions at once.
public actor EntitlementEngine {

    /// How long APNs and FCM keep trying to deliver a message.
    private static let notificationLifetime: TimeInterval = 86_400

    public let storeDelegate: EntitlementStoreDelegate
    public let weeklyProductID: String
    public let monthlyProductID: String
    public let yearlyProductID: String
    public let apnTopic: String
    public let deviceToken: String
    public let messages: EntitlementMessages
    private let now: @Sendable () -> Date
    private let evaluator: EntitlementEvaluator
    private let logger = NeedleTailLogger("[IAPEntitlementEngine]")

    public nonisolated var currentDate: Date { now() }

    /// - Parameters:
    ///   - apnTopic: Required for ``processReceipt(apns:order:orderId:latestReceiptInfo:pendingRenewalInfo:)``.
    ///   - deviceToken: Required for ``processReceipt(apns:order:orderId:latestReceiptInfo:pendingRenewalInfo:)``.
    public init(
        storeDelegate: EntitlementStoreDelegate,
        weeklyProductID: String,
        monthlyProductID: String,
        yearlyProductID: String,
        apnTopic: String = "",
        deviceToken: String = "",
        messages: EntitlementMessages = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeDelegate = storeDelegate
        self.weeklyProductID = weeklyProductID
        self.monthlyProductID = monthlyProductID
        self.yearlyProductID = yearlyProductID
        self.apnTopic = apnTopic
        self.deviceToken = deviceToken
        self.messages = messages
        self.now = now
        self.evaluator = EntitlementEvaluator(catalog: ProductCatalog(
            weekly: weeklyProductID,
            monthly: monthlyProductID,
            yearly: yearlyProductID))
    }

    /// Applies a verified Apple receipt, then notifies the configured device through APNs.
    ///
    /// The order is saved before the push goes out, so a push failure throws but the entitlement
    /// stays correct.
    public func processReceipt(
        apns: some APNSClientProtocol,
        order: Order,
        orderId: String,
        latestReceiptInfo: LatestReceiptInfo,
        pendingRenewalInfo: PendingRenewalInfo
    ) async throws -> HTTPResponse.Status {
        guard !apnTopic.isEmpty, !deviceToken.isEmpty else {
            throw EntitlementError.missingAPNsConfiguration
        }
        let date = now()
        let snapshot = try AppleReceiptAdapter.snapshot(
            latestReceiptInfo: latestReceiptInfo,
            pendingRenewalInfo: pendingRenewalInfo,
            now: date)
        return try await apply(
            snapshot,
            order: order,
            orderId: orderId,
            notifier: APNSEntitlementNotifier(client: apns, topic: apnTopic, deviceToken: deviceToken),
            now: date)
    }

    /// Applies verified App Store Server API or Notifications V2 data, then notifies the device
    /// through `notifier`.
    ///
    /// The order is saved before the push goes out, so a push failure throws but the entitlement
    /// stays correct.
    ///
    /// - Parameters:
    ///   - transaction: The decoded `signedTransactionInfo`. Verify its signature first.
    ///   - renewalInfo: The decoded `signedRenewalInfo`. Verify its signature first.
    public func processAppStoreTransaction(
        notifier: some EntitlementNotifier,
        order: Order,
        orderId: String,
        transaction: AppStoreTransaction,
        renewalInfo: AppStoreRenewalInfo
    ) async throws -> HTTPResponse.Status {
        let date = now()
        let snapshot = try AppStoreSignedDataAdapter.snapshot(
            transaction: transaction,
            renewalInfo: renewalInfo,
            now: date)
        return try await apply(snapshot, order: order, orderId: orderId, notifier: notifier, now: date)
    }

    /// Applies a verified Google Play purchase, then notifies the device through `notifier`.
    ///
    /// The order is saved before the push goes out, so a push failure throws but the entitlement
    /// stays correct.
    ///
    /// - Parameters:
    ///   - purchase: The response of `purchases.subscriptionsv2.get`.
    ///   - isRevoked: Pass `true` for a `SUBSCRIPTION_REVOKED` real-time developer notification.
    public func processGooglePlayPurchase(
        notifier: some EntitlementNotifier,
        order: Order,
        orderId: String,
        purchase: GooglePlaySubscriptionPurchase,
        isRevoked: Bool = false
    ) async throws -> HTTPResponse.Status {
        let snapshot = try GooglePlayAdapter.snapshot(
            purchase: purchase,
            catalog: evaluator.catalog,
            isRevoked: isRevoked)
        return try await apply(snapshot, order: order, orderId: orderId, notifier: notifier, now: now())
    }

    private func apply(
        _ snapshot: SubscriptionSnapshot,
        order: Order,
        orderId: String,
        notifier: some EntitlementNotifier,
        now date: Date
    ) async throws -> HTTPResponse.Status {
        guard let id = UUID(uuidString: orderId) else { throw EntitlementError.invalidOrderID }

        let decision = evaluator.evaluate(snapshot, order: order, now: date)
        logger.log(level: .debug, message: "Evaluated \(snapshot.lifecycle) as \(decision)")

        var updated = order
        if let isSubscribed = decision.isSubscribed {
            updated.isSubscribed = isSubscribed
        }
        if let productName = decision.productName {
            updated.productName = productName
        }
        if updated != order {
            updated.updatedAt = date
            try await storeDelegate.updateOrder(new: updated, id: id)
        }

        if let notification = decision.notification {
            try await notifier.send(
                messages.payload(for: notification),
                collapseID: notification.collapseID,
                expiresAt: date.addingTimeInterval(Self.notificationLifetime))
        }
        return .ok
    }
}
