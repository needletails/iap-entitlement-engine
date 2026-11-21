//
//  PurchaseEngine.swift
//  iap-entitlement-engine
//

import Foundation

/// Turns verified store data about a one-time purchase into a saved ``PurchaseRecord`` and a
/// user notification. It covers consumables, non-consumables and non-renewing purchases.
/// Subscriptions that renew belong to ``EntitlementEngine``.
///
/// The engine trusts its inputs, so verify them with Apple or Google before calling it. Each
/// purchase is granted once and each refund is taken back once, however often and in whatever
/// order the store sends its events, as long as the delegate keeps its records and saves them
/// conditionally.
///
/// A process call throws only when nothing was saved. Once the record is saved the call always
/// returns, and a push that failed is reported in ``PurchaseResult/pushFailure``.
public actor PurchaseEngine {

    /// How long APNs and FCM keep trying to deliver a message.
    private static let notificationLifetime: TimeInterval = 86_400

    private let storeDelegate: any PurchaseStoreDelegate
    private let products: [String: OneTimeProduct]
    private let messages: EntitlementMessages
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - storeDelegate: Reads and saves purchase records, and applies each change to what
    ///     the buyer holds.
    ///   - products: The one-time products you sell. A purchase of anything else is ignored.
    ///     If an ID is listed twice, the first entry is used.
    ///   - messages: The copy for each notification.
    ///   - now: The clock.
    public init(
        storeDelegate: any PurchaseStoreDelegate,
        products: [OneTimeProduct],
        messages: EntitlementMessages = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeDelegate = storeDelegate
        self.products = Dictionary(
            products.filter { !$0.id.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.messages = messages
        self.now = now
    }

    /// Applies a verified App Store transaction, then notifies the device through `notifier`.
    ///
    /// Pass the transaction of a purchase, and pass the one from a `REFUND` or `REVOKE`
    /// notification too: the engine reads `revocationDate` to tell them apart. A
    /// `REFUND_REVERSED` notification goes to ``processAppStoreRefundReversal(notifier:transaction:signedDate:accountID:)``.
    ///
    /// - Parameters:
    ///   - transaction: The decoded `signedTransactionInfo`. Verify its signature first.
    ///   - accountID: Whose purchase this is. When `nil`, the transaction's `appAccountToken`
    ///     is used. A purchase that names nobody throws `missingAccountID`.
    public func processAppStoreTransaction(
        notifier: some EntitlementNotifier,
        transaction: AppStoreTransaction,
        accountID: String? = nil
    ) async throws -> PurchaseResult {
        guard let (snapshot, product) = try appStoreSnapshot(transaction, accountID: accountID) else {
            return PurchaseResult(outcome: .ignored)
        }
        let previous = try await storeDelegate.purchase(transactionID: snapshot.transactionID, store: snapshot.store)
        return try await apply(snapshot, previous: previous, product: product, notifier: notifier, now: now())
    }

    /// Gives back what a refund took, for Apple's `REFUND_REVERSED` notification, then notifies
    /// the device through `notifier`.
    ///
    /// Call this only for that notification. Its transaction looks like the original purchase,
    /// so nothing else can tell a reversal from an old copy of the purchase.
    ///
    /// Apple's notifications can arrive out of order. A reversal that arrives before its refund
    /// is remembered, and the refund is ignored when it comes.
    ///
    /// - Parameters:
    ///   - transaction: The decoded `signedTransactionInfo` of the notification.
    ///   - signedDate: The notification's `signedDate`. It reverses every refund dated before
    ///     it, and no refund dated after it.
    ///   - accountID: Whose purchase this is. See ``processAppStoreTransaction(notifier:transaction:accountID:)``.
    public func processAppStoreRefundReversal(
        notifier: some EntitlementNotifier,
        transaction: AppStoreTransaction,
        signedDate: Date,
        accountID: String? = nil
    ) async throws -> PurchaseResult {
        guard let (snapshot, product) = try appStoreSnapshot(transaction, accountID: accountID) else {
            return PurchaseResult(outcome: .ignored)
        }
        let date = now()
        // One read for the whole call. A second read could see a refund that arrived in between
        // and take this reversal for an old copy of the purchase.
        let found = try await storeDelegate.purchase(transactionID: snapshot.transactionID, store: snapshot.store)
        // A transaction that is still revoked is not a reversal, and is read as it stands. A
        // purchase the engine has never seen is granted, and remembers the reversal.
        guard snapshot.revocation == .none, let previous = found else {
            return try await apply(
                snapshot, previous: found, product: product, notifier: notifier, now: date,
                reversedThrough: snapshot.revocation == .none ? signedDate : nil)
        }
        try check(previous, matches: snapshot, product: product)
        // A reversal no newer than one already applied says nothing new.
        if let through = previous.reversedThrough, signedDate <= through {
            return PurchaseResult(outcome: .unchanged, record: previous, product: product)
        }
        // A reversal signed before the newest refund seen belongs to an earlier refund. Any
        // refund older than the newest one is ignored when it comes, so this needs no memory.
        if let refundedAt = previous.storeRevokedAt, signedDate <= refundedAt {
            return PurchaseResult(outcome: .unchanged, record: previous, product: product)
        }
        var record = previous
        record.accountID = previous.accountID ?? snapshot.accountID
        // Every refund dated before this reversal is reversed by it, seen yet or not.
        record.reversedThrough = signedDate
        record.storeRevokedAt = nil
        guard previous.revokedQuantity > 0 else {
            // The refund has not arrived yet, or took nothing. Remember the reversal so the
            // late refund is ignored.
            return try await save(
                record, replacing: previous, outcome: .unchanged, quantityChange: 0,
                notification: nil, product: product, notifier: notifier, now: date)
        }
        // A purchase first seen refunded may name nobody. Its units cannot come back to nobody.
        guard record.accountID != nil else {
            throw EntitlementError.missingAccountID
        }
        record.revokedQuantity = 0
        record.revokedAt = nil
        record.reinstatedAt = date
        return try await save(
            record, replacing: previous, outcome: .reinstated, quantityChange: previous.revokedQuantity,
            notification: .purchaseReinstated, product: product, notifier: notifier, now: date)
    }

    /// Applies a verified Google Play one-time purchase, then notifies the device through
    /// `notifier`.
    ///
    /// - Parameters:
    ///   - productID: The product ID from the notification, from your client, or from the
    ///     record you saved under the purchase token.
    ///   - purchaseToken: The purchase token. It identifies the purchase.
    ///   - purchase: The response of `purchases.products.get` for that product and token.
    ///     Fetch it after the notification you are handling.
    ///   - voided: That Google took the purchase back, from a `VoidedPurchaseNotification` or
    ///     the Voided Purchases API. `nil` when neither names the purchase.
    ///   - accountID: Whose purchase this is. When `nil`, the purchase's
    ///     `obfuscatedExternalAccountId` is used. A purchase that names nobody throws
    ///     `missingAccountID`.
    public func processGooglePlayPurchase(
        notifier: some EntitlementNotifier,
        productID: String,
        purchaseToken: String,
        purchase: GooglePlayProductPurchase,
        voided: GooglePlayProductPurchase.Voided? = nil,
        accountID: String? = nil
    ) async throws -> PurchaseResult {
        guard !productID.isEmpty else {
            throw EntitlementError.missingProductID
        }
        guard let product = products[productID] else {
            return PurchaseResult(outcome: .ignored)
        }
        guard !purchaseToken.isEmpty else {
            throw EntitlementError.missingTransactionID
        }
        let date = now()
        let quantity = max(1, purchase.quantity ?? 1)

        var revocation: OneTimePurchaseSnapshot.Revocation
        switch voided {
        case .none:
            revocation = .none
        case .full:
            revocation = .all
        case .partial:
            // What can no longer be refunded has been taken back.
            let left = min(quantity, max(0, purchase.refundableQuantity ?? quantity))
            revocation = left == 0 ? .all : .units(quantity - left)
        }
        switch purchase.purchaseState {
        case 0:
            break
        case 1:
            revocation = .all
        case 2:
            // Not paid for yet. A voided pending purchase never becomes a grant either.
            guard revocation != .none else {
                return PurchaseResult(outcome: .pending, product: product)
            }
            revocation = .all
        default:
            throw EntitlementError.unsupportedState("purchaseState \(purchase.purchaseState)")
        }

        var purchasedAt = date
        if let text = purchase.purchaseTimeMillis, !text.isEmpty {
            guard let milliseconds = Int64(text) else {
                throw EntitlementError.invalidDate(field: "purchaseTimeMillis")
            }
            purchasedAt = Date(milliseconds: milliseconds)
        }
        let snapshot = OneTimePurchaseSnapshot(
            store: .googlePlay,
            transactionID: purchaseToken,
            quantity: quantity,
            purchasedAt: purchasedAt,
            revocation: revocation,
            storeRevokedAt: nil,
            accountID: Self.account(accountID, purchase.obfuscatedExternalAccountId),
            orderID: purchase.orderId,
            isTest: purchase.isTestPurchase,
            isFamilyShared: false)
        let previous = try await storeDelegate.purchase(transactionID: snapshot.transactionID, store: snapshot.store)
        return try await apply(snapshot, previous: previous, product: product, notifier: notifier, now: date)
    }

    /// The caller's value, or else the store's. An empty value names nobody.
    private static func account(_ passed: String?, _ attached: String?) -> String? {
        [passed, attached].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Reads an App Store transaction. Returns `nil` for a product the engine does not handle.
    private func appStoreSnapshot(
        _ transaction: AppStoreTransaction, accountID: String?
    ) throws -> (OneTimePurchaseSnapshot, OneTimeProduct)? {
        guard let productID = transaction.productId, !productID.isEmpty else {
            throw EntitlementError.missingProductID
        }
        // Apple names the kind of product. A subscription that renews is not handled here, even
        // if its ID was listed by mistake.
        guard let product = products[productID], transaction.type != "Auto-Renewable Subscription" else {
            return nil
        }
        // A purchase's own ID is its original ID. A restored copy has a new ID and the same
        // original, and is the same purchase.
        let original = transaction.originalTransactionId.flatMap { $0.isEmpty ? nil : $0 }
        guard let transactionID = original ?? transaction.transactionId, !transactionID.isEmpty else {
            throw EntitlementError.missingTransactionID
        }
        let quantity = max(1, Int(transaction.quantity ?? 1))

        var revocation = OneTimePurchaseSnapshot.Revocation.none
        if transaction.revocationDate != nil {
            revocation = .all
            // A prorated refund gives back part of the price. Apple reports the part in
            // thousandths of a percent, and it comes to whole units of a consumable.
            // Anything else cannot be split, and is kept until all of the price is refunded.
            if transaction.revocationType == "REFUND_PRORATED" {
                // Without the part, the refund could be anything from nothing to everything.
                guard let part = transaction.revocationPercentage else {
                    throw EntitlementError.unsupportedState("REFUND_PRORATED without revocationPercentage")
                }
                if part < 100_000 {
                    let units = Int((Double(quantity) * Double(max(part, 0)) / 100_000).rounded())
                    revocation = .units(product.kind == .consumable ? units : 0)
                }
            }
        }
        let snapshot = OneTimePurchaseSnapshot(
            store: .appStore,
            transactionID: transactionID,
            quantity: quantity,
            purchasedAt: transaction.purchaseDate ?? now(),
            revocation: revocation,
            storeRevokedAt: transaction.revocationDate,
            accountID: Self.account(accountID, transaction.appAccountToken),
            orderID: nil,
            isTest: transaction.environment.map { $0 == "Sandbox" || $0 == "Xcode" || $0 == "LocalTesting" } ?? false,
            isFamilyShared: transaction.inAppOwnershipType == "FAMILY_SHARED")
        return (snapshot, product)
    }

    /// One purchase never changes product, and a copy shared with the family is never the
    /// purchase that was paid for. If either seems so, the data is not what it claims, and
    /// acting on it could take a paid purchase away.
    private func check(
        _ record: PurchaseRecord, matches snapshot: OneTimePurchaseSnapshot, product: OneTimeProduct
    ) throws {
        guard record.productID == product.id, record.store == snapshot.store,
              record.isFamilyShared == snapshot.isFamilyShared
        else {
            throw EntitlementError.transactionMismatch
        }
    }

    private func apply(
        _ snapshot: OneTimePurchaseSnapshot,
        previous: PurchaseRecord?,
        product: OneTimeProduct,
        notifier: some EntitlementNotifier,
        now date: Date,
        reversedThrough: Date? = nil
    ) async throws -> PurchaseResult {
        let isConsumable = product.kind == .consumable
        guard let previous else {
            // Only a consumable can be bought in multiples.
            let quantity = isConsumable ? snapshot.quantity : 1
            let revoked = snapshot.revokedUnits(of: quantity, isConsumable: isConsumable)
            // Units that are granted have to be granted to someone. A purchase first seen fully
            // refunded is held by nobody, and is recorded so that it is never granted later.
            guard revoked >= quantity || snapshot.accountID != nil else {
                throw EntitlementError.missingAccountID
            }
            var expiresAt: Date?
            if case .nonRenewing(let duration) = product.kind {
                expiresAt = snapshot.purchasedAt.addingTimeInterval(duration)
            }
            let record = PurchaseRecord(
                transactionID: snapshot.transactionID,
                productID: product.id,
                store: snapshot.store,
                accountID: snapshot.accountID,
                orderID: snapshot.orderID,
                quantity: quantity,
                purchasedAt: snapshot.purchasedAt,
                expiresAt: expiresAt,
                revokedQuantity: revoked,
                revokedAt: revoked > 0 ? date : nil,
                storeRevokedAt: snapshot.storeRevokedAt,
                reversedThrough: reversedThrough,
                isTest: snapshot.isTest,
                isFamilyShared: snapshot.isFamilyShared,
                revision: 1,
                updatedAt: date)
            return try await save(
                record, replacing: nil,
                outcome: record.isRevoked ? .revoked : .granted,
                quantityChange: record.remainingQuantity,
                notification: record.isRevoked ? nil : .purchased,
                product: product, notifier: notifier, now: date)
        }

        try check(previous, matches: snapshot, product: product)
        let claimed = snapshot.revokedUnits(of: previous.quantity, isConsumable: isConsumable)
        var record = previous
        // A purchase first seen refunded may name nobody. The first event that names the buyer
        // says whose it is.
        record.accountID = previous.accountID ?? snapshot.accountID
        var revoked = previous.revokedQuantity
        if let refundedAt = snapshot.storeRevokedAt {
            // Apple dates its refunds, and the newest snapshot of the transaction is the true one.
            if let reversed = previous.reversedThrough, refundedAt < reversed {
                // Reversed, whether it is a resent copy of an old refund or one that arrives
                // after its own reversal.
            } else if let newest = previous.storeRevokedAt {
                if refundedAt > newest {
                    // A refund can only follow another once the first was reversed, so this one
                    // replaces it, even when it takes back less.
                    revoked = claimed
                    record.storeRevokedAt = refundedAt
                } else if refundedAt == newest {
                    revoked = max(revoked, claimed)
                }
                // An older refund than the newest seen says nothing new.
            } else {
                revoked = max(revoked, claimed)
                record.storeRevokedAt = refundedAt
            }
        } else {
            // Google's voids carry no date and are never undone, so they only grow. A stale
            // read must not hand back what was taken.
            revoked = max(revoked, claimed)
        }
        revoked = min(previous.quantity, revoked)
        record.revokedQuantity = revoked
        let change = previous.revokedQuantity - revoked
        if change == 0 {
            guard record != previous else {
                return PurchaseResult(outcome: .unchanged, record: previous, product: product)
            }
            // Only the bookkeeping changed: the newest refund's date, or whose purchase it is.
            return try await save(
                record, replacing: previous, outcome: .unchanged, quantityChange: 0,
                notification: nil, product: product, notifier: notifier, now: date)
        }
        if change > 0 {
            // A newer refund that takes back less than the one it replaces.
            guard record.accountID != nil else {
                throw EntitlementError.missingAccountID
            }
            record.revokedAt = revoked > 0 ? previous.revokedAt : nil
            record.reinstatedAt = date
            return try await save(
                record, replacing: previous, outcome: .reinstated, quantityChange: change,
                notification: .purchaseReinstated, product: product, notifier: notifier, now: date)
        }
        record.revokedAt = previous.revokedAt ?? date
        return try await save(
            record, replacing: previous, outcome: .revoked, quantityChange: change,
            notification: .purchaseRefunded, product: product, notifier: notifier, now: date)
    }

    private func save(
        _ changed: PurchaseRecord,
        replacing previous: PurchaseRecord?,
        outcome: PurchaseResult.Outcome,
        quantityChange: Int,
        notification: EntitlementNotification?,
        product: OneTimeProduct,
        notifier: some EntitlementNotifier,
        now date: Date
    ) async throws -> PurchaseResult {
        var record = changed
        record.revision = (previous?.revision ?? 0) + 1
        record.updatedAt = date
        try await storeDelegate.savePurchase(record, replacing: previous, quantityChange: quantityChange)

        // The record is saved, so from here a failure is reported rather than thrown.
        var pushFailure: (any Error)?
        if let notification {
            do {
                try await notifier.send(
                    messages.payload(for: notification),
                    for: notification,
                    expiresAt: date.addingTimeInterval(Self.notificationLifetime))
            } catch {
                pushFailure = error
            }
        }
        return PurchaseResult(
            outcome: outcome, record: record, product: product, quantityChange: quantityChange,
            didSave: true, notification: notification, pushFailure: pushFailure)
    }
}

/// What a store says about one one-time purchase.
private struct OneTimePurchaseSnapshot {
    enum Revocation: Equatable {
        case none
        case all
        /// Fewer units than were bought.
        case units(Int)
    }

    let store: PurchaseRecord.Store
    let transactionID: String
    /// The units the store says were bought.
    let quantity: Int
    let purchasedAt: Date
    let revocation: Revocation
    /// Apple's `revocationDate`.
    let storeRevokedAt: Date?
    let accountID: String?
    let orderID: String?
    let isTest: Bool
    let isFamilyShared: Bool

    /// How many of a record's units are taken back.
    ///
    /// A consumable loses the units the store names. Anything else is one unit whatever
    /// quantity the store shows, and is kept for as long as any paid unit remains.
    func revokedUnits(of recorded: Int, isConsumable: Bool) -> Int {
        switch revocation {
        case .none: 0
        case .all: recorded
        case .units(let units):
            isConsumable
                ? min(recorded, max(0, units))
                : max(0, recorded - max(0, quantity - max(0, units)))
        }
    }
}
