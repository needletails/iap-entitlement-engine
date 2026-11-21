import Foundation
import Testing
@testable import IAPEntitlementEngine

private func send(_ events: [AppleEvent], product: String = "coins.100", quantity: Int32 = 3) async throws -> LedgerStore {
    let store = LedgerStore()
    let engine = r3engine(store)
    for event in events { _ = try await event.send(to: engine, product: product, quantity: quantity) }
    return store
}

@Suite("One-time purchases: refunds of different sizes and nameless records")
struct OneTimePurchaseOrderingTests {
    /// Finding 1. A lifetime unlock is taken away by a refund of half its price.
    @Test(arguments: [Int64(50_000), 66_667, 99_999])
    func aProratedRefundOfHalfOrMoreLeavesANonConsumable(pct: Int64) async throws {
        for product in ["pro.unlock", "season.pass"] {
            let store = try await send(
                [AppleEvent(kind: .plain), AppleEvent(kind: .refund, at: 100, pct: pct)], product: product, quantity: 1)
            #expect(store.balance == 1, "\(product) at \(pct): holds \(store.balance)")
        }
    }

    /// Finding 2. The same four events, the reversal delivered last instead of third.
    @Test func aLateReversalOfTheFirstRefundDoesNotLeaveItsUnitsTaken() async throws {
        let purchase = AppleEvent(kind: .plain)
        let full = AppleEvent(kind: .refund, at: 100)
        let reversal = AppleEvent(kind: .reversal, at: 200)
        let third = AppleEvent(kind: .refund, at: 300, pct: 33_333)
        let inOrder = try await send([purchase, full, reversal, third])
        let late = try await send([purchase, full, third, reversal])
        #expect(inOrder.balance == 2)
        #expect(late.balance == 2, "reversal delivered last: holds \(late.balance)")
    }

    /// Finding 2. A reversal older than the refund in force is not remembered, so the refund it
    /// reversed is applied when it arrives late.
    @Test func aRefundAlreadyReversedIsNotAppliedOnTopOfANewerPartialRefund() async throws {
        let store = try await send([
            AppleEvent(kind: .plain), AppleEvent(kind: .refund, at: 300, pct: 33_333),
            AppleEvent(kind: .reversal, at: 200), AppleEvent(kind: .refund, at: 100),
        ])
        #expect(store.balance == 2, "holds \(store.balance)")
    }

    /// Finding 3. Units come back to a record that names nobody, even when the call names the buyer.
    @Test func aReversalNeverGivesUnitsToNobody() async throws {
        let store = LedgerStore()
        let engine = r3engine(store)
        var refund = AppleEvent(kind: .refund, at: 100).transaction(product: "coins.100", quantity: 3)
        refund.appAccountToken = nil
        var plain = AppleEvent(kind: .plain).transaction(product: "coins.100", quantity: 3)
        plain.appAccountToken = nil
        // The REFUND webhook is first, and the app attaches no account token.
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: refund)
        // The app's own call names the buyer.
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: plain, accountID: "user-1")
        // REFUND_REVERSED, and the caller even looked the buyer up.
        let reversed = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: plain, signedDate: now.addingTimeInterval(200), accountID: "user-1")
        #expect(reversed.quantityChange == 3)
        #expect(reversed.record?.accountID == "user-1", "three units went to account \(String(describing: reversed.record?.accountID))")
        #expect(store.unitsToNobody == 0)
    }

    /// Finding 3, with nobody named anywhere: the call must throw rather than save.
    @Test func aReversalWithNobodyToGiveToThrows() async throws {
        let store = LedgerStore()
        let engine = r3engine(store)
        var refund = AppleEvent(kind: .refund, at: 100).transaction(product: "coins.100", quantity: 3)
        refund.appAccountToken = nil
        var plain = AppleEvent(kind: .plain).transaction(product: "coins.100", quantity: 3)
        plain.appAccountToken = nil
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: refund)
        await #expect(throws: EntitlementError.missingAccountID) {
            try await engine.processAppStoreRefundReversal(
                notifier: RecordingNotifier(), transaction: plain, signedDate: now.addingTimeInterval(200))
        }
        #expect(store.unitsToNobody == 0)
    }
}

/// Edge cases that looked doubtful and hold, and two behaviours worth knowing about.
@Suite("One-time purchases: edge cases that hold")
struct OneTimePurchaseEdgeCaseTests {
    @Test func aProratedThenAFullRefundAtAnyDateTakesEverything() async throws {
        for at in [50.0, 100, 300] {
            let store = try await send([
                AppleEvent(kind: .plain), AppleEvent(kind: .refund, at: 100, pct: 33_333), AppleEvent(kind: .refund, at: at),
            ])
            // A full refund dated before the prorated one is the older snapshot and is ignored.
            // A later or equally dated one takes everything.
            if at >= 100 { #expect(store.balance == 0) }
        }
    }

    @Test func aReversalSignedBetweenAProratedAndAFullRefundLeavesTheFullOne() async throws {
        for order in permutations([
            AppleEvent(kind: .refund, at: 100, pct: 33_333), AppleEvent(kind: .refund, at: 300), AppleEvent(kind: .reversal, at: 200),
        ]) {
            let store = try await send([AppleEvent(kind: .plain)] + order)
            #expect(store.balance == 0, "\(order)")
            #expect(store.record("tx-1")?.storeRevokedAt == now.addingTimeInterval(300))
        }
    }

    /// `max(refundedAt, previous.storeRevokedAt ?? refundedAt)`: an old date cannot come back.
    @Test func anOldRefundDateDoesNotComeBackAfterAReinstatement() async throws {
        let store = try await send([
            AppleEvent(kind: .plain), AppleEvent(kind: .refund, at: 100), AppleEvent(kind: .reversal, at: 200),
            AppleEvent(kind: .refund, at: 100), AppleEvent(kind: .refund, at: 300), AppleEvent(kind: .refund, at: 100),
        ])
        #expect(store.record("tx-1")?.storeRevokedAt == now.addingTimeInterval(300))
        #expect(store.balance == 0)
    }

    @Test func aReversalOfAnUnknownPurchaseIsRememberedForBothRefunds() async throws {
        let before = try await send([AppleEvent(kind: .reversal, at: 200), AppleEvent(kind: .refund, at: 100)])
        #expect(before.record("tx-1")?.reversedThrough == now.addingTimeInterval(200))
        #expect(before.balance == 3)
        let after = try await send([AppleEvent(kind: .reversal, at: 200), AppleEvent(kind: .refund, at: 300)])
        #expect(after.balance == 0)
    }

    @Test func aReversalOfAnUnknownPurchaseWithNoAccountSavesNothing() async throws {
        let store = LedgerStore()
        await #expect(throws: EntitlementError.missingAccountID) {
            try await AppleEvent(kind: .reversal, at: 200, account: false).send(to: r3engine(store), product: "coins.100", quantity: 3)
        }
        #expect(store.saves == 0)
    }

    /// The throw leaves the partial refund unrecorded. The purchase is then granted in full, and
    /// the total is right only once the refund is delivered again.
    @Test func aPartialRefundThatNamesNobodyHasToBeRedelivered() async throws {
        let store = LedgerStore()
        let engine = r3engine(store)
        let refund = AppleEvent(kind: .refund, at: 100, pct: 33_333, account: false)
        await #expect(throws: EntitlementError.missingAccountID) {
            try await refund.send(to: engine, product: "coins.100", quantity: 3)
        }
        _ = try await AppleEvent(kind: .plain).send(to: engine, product: "coins.100", quantity: 3)
        #expect(store.balance == 3)
        _ = try await refund.send(to: engine, product: "coins.100", quantity: 3)
        #expect(store.balance == 2)
    }

    @Test(arguments: [("Sandbox", true), ("Xcode", true), ("LocalTesting", true), ("Production", false), ("sandbox", false), ("Future", false)])
    func onlyTheThreeTestEnvironmentsAreTests(environment: String, isTest: Bool) async throws {
        let store = LedgerStore()
        var transaction = AppleEvent(kind: .plain).transaction(product: "coins.100", quantity: 1)
        transaction.environment = environment
        _ = try await r3engine(store).processAppStoreTransaction(notifier: RecordingNotifier(), transaction: transaction)
        #expect(store.record("tx-1")?.isTest == isTest)
    }

    /// The buyer's own record survives a transaction with and without `inAppOwnershipType`.
    @Test func theBuyersOwnEventsNeverMismatch() async throws {
        let store = LedgerStore()
        let engine = r3engine(store)
        var transaction = AppleEvent(kind: .plain).transaction(product: "pro.unlock", quantity: 1)
        for ownership in [String?.none, "PURCHASED", nil, "PURCHASED"] {
            transaction.inAppOwnershipType = ownership
            _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: transaction)
        }
        #expect(store.balance == 1)
    }

    /// A family member's record first made from a transaction that lost the field can never be
    /// revoked: every later event that has the field throws.
    @Test func aFamilyRecordMadeWithoutTheFieldRejectsItsOwnRevocation() async throws {
        let store = LedgerStore()
        let engine = r3engine(store)
        var transaction = AppleEvent(kind: .plain).transaction(product: "pro.unlock", quantity: 1)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: transaction)
        transaction.inAppOwnershipType = "FAMILY_SHARED"
        transaction.revocationDate = now
        transaction.revocationType = "FAMILY_REVOKE"
        await #expect(throws: EntitlementError.transactionMismatch) {
            try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: transaction)
        }
        #expect(store.balance == 1)
    }

    /// Google: a partial void read with another quantity than the record's.
    @Test func aPartialVoidAgainstAnotherQuantityIsCappedAtTheRecord() async throws {
        let store = LedgerStore()
        let engine = r3engine(store)
        func process(_ quantity: Int?, _ refundable: Int?, _ voided: GooglePlayProductPurchase.Voided?) async throws -> PurchaseResult {
            try await engine.processGooglePlayPurchase(
                notifier: RecordingNotifier(), productID: "coins.100", purchaseToken: "token",
                purchase: GooglePlayProductPurchase(
                    purchaseState: 0, quantity: quantity, refundableQuantity: refundable, obfuscatedExternalAccountId: "buyer"),
                voided: voided)
        }
        _ = try await process(2, nil, nil)
        let result = try await process(5, 1, .partial)
        #expect(result.record?.revokedQuantity == 2)
        #expect(store.balance == 0)
    }
}
