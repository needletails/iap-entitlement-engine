import Foundation
import Synchronization
import Testing
@testable import IAPEntitlementEngine

/// Keeps purchases in memory and refuses a write that would undo another, as a real store should.
final class RecordingPurchaseStore: PurchaseStoreDelegate {
    private let state = Mutex<[String: PurchaseRecord]>([:])
    private let writes = Mutex<[PurchaseRecord]>([])
    private let balance = Mutex<Int>(0)
    let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    var saved: [PurchaseRecord] { writes.withLock { $0 } }

    /// What the buyer holds, from the changes the engine handed over with each save.
    var held: Int { balance.withLock { $0 } }

    func record(_ transactionID: String) -> PurchaseRecord? { state.withLock { $0[transactionID] } }

    func purchase(transactionID: String, store: PurchaseRecord.Store) async throws -> PurchaseRecord? {
        state.withLock { $0[transactionID] }
    }

    func savePurchase(
        _ record: PurchaseRecord, replacing previous: PurchaseRecord?, quantityChange: Int
    ) async throws {
        if let failure { throw failure }
        try state.withLock {
            guard $0[record.transactionID]?.revision == previous?.revision else { throw TestFailure.boom }
            $0[record.transactionID] = record
        }
        writes.withLock { $0.append(record) }
        balance.withLock { $0 += quantityChange }
    }
}

private let coins = OneTimeProduct(id: "coins.100", kind: .consumable)
private let unlock = OneTimeProduct(id: "pro.unlock", kind: .nonConsumable)
private let pass = OneTimeProduct(id: "season.pass", kind: .nonRenewing(duration: 30 * 86_400))

private func engine(_ store: RecordingPurchaseStore, clock: TestClock = TestClock(now)) -> PurchaseEngine {
    PurchaseEngine(storeDelegate: store, products: [coins, unlock, pass], now: { clock.value })
}

private func apple(
    _ product: String,
    id: String? = "tx-1",
    original: String? = nil,
    quantity: Int32? = nil,
    type: String? = nil,
    revoked: Date? = nil
) -> AppStoreTransaction {
    AppStoreTransaction(
        productId: product, originalTransactionId: original, revocationDate: revoked, transactionId: id,
        type: type, quantity: quantity, purchaseDate: now.addingTimeInterval(-60), appAccountToken: "buyer")
}

private func google(
    state: Int = 0, quantity: Int? = nil, refundable: Int? = nil, acknowledged: Int? = 1
) -> GooglePlayProductPurchase {
    GooglePlayProductPurchase(
        purchaseState: state, acknowledgementState: acknowledged, quantity: quantity,
        refundableQuantity: refundable, obfuscatedExternalAccountId: "buyer",
        purchaseTimeMillis: milliseconds(now.addingTimeInterval(-60)))
}

@Suite("One-time purchases from the App Store")
struct AppStoreOneTimePurchaseTests {
    @Test func aNewConsumableIsGrantedOnceWithItsQuantity() async throws {
        let store = RecordingPurchaseStore()
        let notifier = RecordingNotifier()
        let result = try await engine(store).processAppStoreTransaction(
            notifier: notifier, transaction: apple("coins.100", quantity: 3))

        #expect(result.outcome == .granted)
        #expect(result.quantityChange == 3)
        #expect(result.didSave)
        #expect(result.product == coins)
        #expect(store.record("tx-1")?.quantity == 3)
        #expect(store.record("tx-1")?.purchasedAt == now.addingTimeInterval(-60))
        #expect(notifier.sent.map(\.notification) == [.purchased])
    }

    @Test func theSameTransactionTwiceIsGrantedOnce() async throws {
        let store = RecordingPurchaseStore()
        let notifier = RecordingNotifier()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: notifier, transaction: apple("coins.100"))
        let again = try await engine.processAppStoreTransaction(notifier: notifier, transaction: apple("coins.100"))

        #expect(again.outcome == .unchanged)
        #expect(again.quantityChange == 0)
        #expect(!again.didSave)
        #expect(again.record == store.record("tx-1"))
        #expect(store.saved.count == 1)
        #expect(notifier.sent.count == 1)
    }

    @Test func twoPurchasesOfAConsumableAreBothGranted() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        let first = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", id: "tx-1"))
        let second = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", id: "tx-2"))
        #expect(first.outcome == .granted)
        #expect(second.outcome == .granted)
        #expect(store.saved.count == 2)
    }

    @Test func aNonConsumableIsOwnedOnceWhateverTheQuantitySays() async throws {
        let store = RecordingPurchaseStore()
        let result = try await engine(store).processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("pro.unlock", quantity: 5))
        #expect(result.outcome == .granted)
        #expect(result.quantityChange == 1)
        #expect(result.record?.quantity == 1)
        #expect(result.accessExpiresAt == nil)
    }

    @Test func aRefundTakesBackWhatWasGranted() async throws {
        let store = RecordingPurchaseStore()
        let notifier = RecordingNotifier()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: notifier, transaction: apple("coins.100", quantity: 2))
        let refund = try await engine.processAppStoreTransaction(
            notifier: notifier, transaction: apple("coins.100", quantity: 2, revoked: now))

        #expect(refund.outcome == .revoked)
        #expect(refund.quantityChange == -2)
        #expect(refund.didSave)
        #expect(store.record("tx-1")?.isRevoked == true)
        #expect(store.record("tx-1")?.revokedAt == now)
        #expect(notifier.sent.map(\.notification) == [.purchased, .purchaseRefunded])
    }

    @Test func aRefundTwiceTakesBackOnce() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now))
        let again = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now))
        #expect(again.outcome == .unchanged)
        #expect(again.quantityChange == 0)
        #expect(store.saved.count == 2)
    }

    /// The refund can arrive first. The purchase that follows must not hand the item out.
    @Test func aRefundSeenFirstBlocksTheLatePurchase() async throws {
        let store = RecordingPurchaseStore()
        let notifier = RecordingNotifier()
        let engine = engine(store)
        let refund = try await engine.processAppStoreTransaction(
            notifier: notifier, transaction: apple("pro.unlock", revoked: now))
        #expect(refund.outcome == .revoked)
        #expect(refund.quantityChange == 0)
        #expect(refund.didSave)

        let late = try await engine.processAppStoreTransaction(notifier: notifier, transaction: apple("pro.unlock"))
        #expect(late.outcome == .unchanged)
        #expect(late.quantityChange == 0)
        #expect(store.record("tx-1")?.isRevoked == true)
        #expect(notifier.sent.isEmpty)
    }

    @Test func aProductThatIsNotSoldIsIgnored() async throws {
        let store = RecordingPurchaseStore()
        let notifier = RecordingNotifier()
        let result = try await engine(store).processAppStoreTransaction(
            notifier: notifier, transaction: apple("something.else"))
        #expect(result.outcome == .ignored)
        #expect(result.record == nil)
        #expect(result.product == nil)
        #expect(store.saved.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    @Test func aSubscriptionTransactionIsLeftToTheSubscriptionEngine() async throws {
        let store = RecordingPurchaseStore()
        let result = try await engine(store).processAppStoreTransaction(
            notifier: RecordingNotifier(),
            transaction: apple("pro.unlock", type: "Auto-Renewable Subscription"))
        #expect(result.outcome == .ignored)
        #expect(store.saved.isEmpty)
    }

    @Test func aTransactionWithoutAnIDIsAnError() async throws {
        let store = RecordingPurchaseStore()
        await #expect(throws: EntitlementError.missingTransactionID) {
            try await engine(store).processAppStoreTransaction(
                notifier: RecordingNotifier(), transaction: apple("coins.100", id: nil))
        }
        await #expect(throws: EntitlementError.missingTransactionID) {
            try await engine(store).processAppStoreTransaction(
                notifier: RecordingNotifier(), transaction: apple("coins.100", id: ""))
        }
        #expect(store.saved.isEmpty)
    }

    @Test func aTransactionWithoutAProductIsAnError() async throws {
        await #expect(throws: EntitlementError.missingProductID) {
            try await engine(RecordingPurchaseStore()).processAppStoreTransaction(
                notifier: RecordingNotifier(), transaction: AppStoreTransaction(transactionId: "tx-1"))
        }
    }

    /// One transaction ID never changes product. If it seems to, the data is not what it claims.
    @Test func aTransactionThatChangesProductIsAnError() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        await #expect(throws: EntitlementError.transactionMismatch) {
            try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("pro.unlock"))
        }
        #expect(store.saved.count == 1)
    }

    @Test func aNonRenewingPurchaseRunsForItsDuration() async throws {
        let store = RecordingPurchaseStore()
        let result = try await engine(store).processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("season.pass"))
        let ends = now.addingTimeInterval(-60 + 30 * 86_400)
        #expect(result.outcome == .granted)
        #expect(result.accessExpiresAt == ends)
        #expect(store.record("tx-1")?.expiresAt == ends)
        #expect(store.record("tx-1")?.isActive(at: now) == true)
        #expect(store.record("tx-1")?.isActive(at: ends) == false)
    }

    @Test func aRefundedNonRenewingPurchaseHasNoAccess() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("season.pass"))
        let refund = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("season.pass", revoked: now))
        #expect(refund.accessExpiresAt == nil)
        #expect(store.record("tx-1")?.isActive(at: now) == false)
    }

    @Test func nothingIsPushedWhenTheSaveFails() async throws {
        let store = RecordingPurchaseStore(failure: TestFailure.boom)
        let notifier = RecordingNotifier()
        await #expect(throws: TestFailure.boom) {
            try await engine(store).processAppStoreTransaction(notifier: notifier, transaction: apple("coins.100"))
        }
        #expect(notifier.sent.isEmpty)
    }

    @Test func aFailedPushIsReportedAndThePurchaseStands() async throws {
        let store = RecordingPurchaseStore()
        let result = try await engine(store).processAppStoreTransaction(
            notifier: RecordingNotifier(failure: TestFailure.boom), transaction: apple("coins.100"))
        #expect(result.outcome == .granted)
        #expect(result.notification == .purchased)
        #expect(result.pushFailure as? TestFailure == .boom)
        #expect(store.saved.count == 1)
    }

    @Test func theTransactionDecodesTheFieldsAOneTimePurchaseNeeds() throws {
        let json = """
            {"productId":"coins.100","transactionId":"2000000123","originalTransactionId":"2000000123",
             "type":"Consumable","quantity":2,"purchaseDate":1800000000000}
            """
        let transaction = try JSONDecoder().decode(AppStoreTransaction.self, from: Data(json.utf8))
        #expect(transaction.transactionId == "2000000123")
        #expect(transaction.type == "Consumable")
        #expect(transaction.quantity == 2)
        #expect(transaction.purchaseDate == now)
    }
}

@Suite("One-time purchases from Google Play")
struct GooglePlayOneTimePurchaseTests {
    private func process(
        _ engine: PurchaseEngine, _ purchase: GooglePlayProductPurchase, product: String = "coins.100",
        token: String = "token-1", voided: GooglePlayProductPurchase.Voided? = nil,
        notifier: RecordingNotifier = RecordingNotifier()
    ) async throws -> PurchaseResult {
        try await engine.processGooglePlayPurchase(
            notifier: notifier, productID: product, purchaseToken: token, purchase: purchase, voided: voided)
    }

    @Test func aPurchaseIsGrantedOnceByItsToken() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        let first = try await process(engine, google(quantity: 4))
        let again = try await process(engine, google(quantity: 4))
        #expect(first.outcome == .granted)
        #expect(first.quantityChange == 4)
        #expect(store.record("token-1")?.purchasedAt == now.addingTimeInterval(-60))
        #expect(again.outcome == .unchanged)
        #expect(store.saved.count == 1)
    }

    @Test func aMissingQuantityIsOne() async throws {
        let result = try await process(engine(RecordingPurchaseStore()), google())
        #expect(result.quantityChange == 1)
    }

    /// A pending purchase is not paid for yet. Granting it would give the item away.
    @Test func aPendingPurchaseGrantsNothing() async throws {
        let store = RecordingPurchaseStore()
        let notifier = RecordingNotifier()
        let engine = engine(store)
        let pending = try await process(engine, google(state: 2), notifier: notifier)
        #expect(pending.outcome == .pending)
        #expect(pending.quantityChange == 0)
        #expect(store.saved.isEmpty)
        #expect(notifier.sent.isEmpty)

        let paid = try await process(engine, google(state: 0), notifier: notifier)
        #expect(paid.outcome == .granted)
    }

    @Test func aCancelledPurchaseThatWasNeverGrantedGrantsNothing() async throws {
        let store = RecordingPurchaseStore()
        let result = try await process(engine(store), google(state: 1))
        #expect(result.outcome == .revoked)
        #expect(result.quantityChange == 0)
        #expect(store.record("token-1")?.isRevoked == true)
    }

    @Test func aVoidedPurchaseIsTakenBack() async throws {
        let store = RecordingPurchaseStore()
        let notifier = RecordingNotifier()
        let engine = engine(store)
        _ = try await process(engine, google(quantity: 2), notifier: notifier)
        let voided = try await process(engine, google(quantity: 2), voided: .full, notifier: notifier)
        #expect(voided.outcome == .revoked)
        #expect(voided.quantityChange == -2)
        #expect(notifier.sent.map(\.notification) == [.purchased, .purchaseRefunded])
    }

    /// For a partial void the engine reads what is left from the purchase just fetched.
    @Test func aPartialVoidTakesBackOnlyThatPart() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await process(engine, google(quantity: 5, refundable: 5))
        let partial = try await process(engine, google(quantity: 5, refundable: 3), voided: .partial)
        #expect(partial.outcome == .revoked)
        #expect(partial.quantityChange == -2)
        #expect(store.record("token-1")?.revokedQuantity == 2)
        #expect(store.record("token-1")?.isRevoked == false)
        #expect(store.record("token-1")?.remainingQuantity == 3)
        let firstRevokedAt = store.record("token-1")?.revokedAt

        let same = try await process(engine, google(quantity: 5, refundable: 3), voided: .partial)
        #expect(same.outcome == .unchanged)

        let rest = try await process(engine, google(quantity: 5, refundable: 0), voided: .partial)
        #expect(rest.quantityChange == -3)
        #expect(store.record("token-1")?.isRevoked == true)
        #expect(store.record("token-1")?.revokedAt == firstRevokedAt)
        #expect(store.record("token-1")?.updatedAt == now)
        #expect(store.held == 0)
    }

    /// A read that is older than what the engine has seen must never hand units back.
    @Test func aVoidIsNeverUndone() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await process(engine, google(quantity: 5))
        _ = try await process(engine, google(quantity: 5, refundable: 1), voided: .partial)
        let stale = try await process(engine, google(quantity: 5, refundable: 4), voided: .partial)
        let none = try await process(engine, google(quantity: 5))
        #expect(stale.outcome == .unchanged)
        #expect(none.outcome == .unchanged)
        #expect(store.record("token-1")?.revokedQuantity == 4)
        #expect(store.held == 1)
    }

    /// Google can refund the money and leave the item with the buyer. Only a void takes it.
    @Test func aRefundThatGoogleDoesNotVoidLeavesTheItem() async throws {
        let store = RecordingPurchaseStore()
        let notifier = RecordingNotifier()
        let engine = engine(store)
        _ = try await process(engine, google(quantity: 5, refundable: 5), notifier: notifier)
        let refunded = try await process(engine, google(quantity: 5, refundable: 0), notifier: notifier)
        #expect(refunded.outcome == .unchanged)
        #expect(store.held == 5)
        #expect(notifier.sent.map(\.notification) == [.purchased])
    }

    @Test func aPartialVoidWithNothingMissingChangesNothing() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await process(engine, google(quantity: 5))
        let result = try await process(engine, google(quantity: 5), voided: .partial)
        #expect(result.outcome == .unchanged)
        #expect(store.held == 5)
    }

    @Test func aPurchaseFirstSeenPartlyVoidedGrantsTheRest() async throws {
        let store = RecordingPurchaseStore()
        let result = try await process(engine(store), google(quantity: 5, refundable: 3), voided: .partial)
        #expect(result.outcome == .granted)
        #expect(result.quantityChange == 3)
        #expect(store.record("token-1")?.revokedQuantity == 2)
        #expect(store.record("token-1")?.revokedAt == now)
    }

    /// One unlock was bought five times over. While any paid unit remains, the unlock stays.
    @Test func aPartialVoidOfAMultiQuantityUnlockKeepsTheUnlock() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await process(engine, google(quantity: 5), product: "pro.unlock")
        let partial = try await process(
            engine, google(quantity: 5, refundable: 1), product: "pro.unlock", voided: .partial)
        #expect(partial.outcome == .unchanged)
        #expect(store.record("token-1")?.isRevoked == false)

        let all = try await process(
            engine, google(quantity: 5, refundable: 0), product: "pro.unlock", voided: .partial)
        #expect(all.quantityChange == -1)
        #expect(store.record("token-1")?.isRevoked == true)
    }

    @Test func aMultiQuantityUnlockFirstSeenPartlyVoidedIsGrantedOnce() async throws {
        let store = RecordingPurchaseStore()
        let result = try await process(
            engine(store), google(quantity: 5, refundable: 1), product: "pro.unlock", voided: .partial)
        #expect(result.outcome == .granted)
        #expect(result.quantityChange == 1)
        #expect(store.held == 1)
    }

    @Test func aPartialVoidOfAMultiQuantityPassKeepsThePass() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await process(engine, google(quantity: 2), product: "season.pass")
        _ = try await process(engine, google(quantity: 2, refundable: 1), product: "season.pass", voided: .partial)
        #expect(store.record("token-1")?.isActive(at: now) == true)
    }

    /// The record holds what was bought. A later response that shows another quantity does not
    /// turn a partial void into a full one.
    @Test func aVoidReadAgainstAnotherQuantityTakesOnlyItsUnits() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await process(engine, google(quantity: 5))
        let result = try await process(engine, google(quantity: 2, refundable: 1), voided: .partial)
        #expect(result.quantityChange == -1)
        #expect(store.held == 4)
    }

    @Test func aPartlyVoidedPendingPurchaseGrantsNothing() async throws {
        let store = RecordingPurchaseStore()
        let result = try await process(engine(store), google(state: 2, quantity: 5, refundable: 3), voided: .partial)
        #expect(result.outcome == .revoked)
        #expect(store.held == 0)
    }

    @Test func aVoidedPendingPurchaseIsRecordedAsTakenBack() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        let result = try await process(engine, google(state: 2), voided: .full)
        #expect(result.outcome == .revoked)
        #expect(result.quantityChange == 0)
        let late = try await process(engine, google(state: 0))
        #expect(late.outcome == .unchanged)
        #expect(store.held == 0)
    }

    @Test func oddQuantitiesAreClamped() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        let zero = try await process(engine, google(quantity: 0), token: "a")
        #expect(zero.quantityChange == 1)
        let negative = try await process(engine, google(quantity: 2, refundable: -4), token: "b", voided: .partial)
        #expect(negative.outcome == .revoked)
        #expect(store.record("b")?.revokedQuantity == 2)
        let tooMany = try await process(engine, google(quantity: 2, refundable: 9), token: "c", voided: .partial)
        #expect(tooMany.outcome == .granted)
        #expect(tooMany.quantityChange == 2)
        let apple = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", id: "d", original: "", quantity: -2))
        #expect(apple.quantityChange == 1)
        #expect(store.record("d") != nil)
    }

    @Test func theRecordKeepsWhatIdentifiesThePurchase() async throws {
        let store = RecordingPurchaseStore()
        var purchase = google()
        purchase.orderId = "GPA.1"
        purchase.obfuscatedExternalAccountId = "account-7"
        purchase.purchaseType = 0
        _ = try await process(engine(store), purchase)
        let record = try #require(store.record("token-1"))
        #expect(record.store == .googlePlay)
        #expect(record.orderID == "GPA.1")
        #expect(record.accountID == "account-7")
        #expect(record.isTest)
        #expect(record.revision == 1)
    }

    @Test func aPurchaseTimeThatCannotBeReadIsAnError() async throws {
        var purchase = google()
        purchase.purchaseTimeMillis = "yesterday"
        await #expect(throws: EntitlementError.invalidDate(field: "purchaseTimeMillis")) {
            try await process(engine(RecordingPurchaseStore()), purchase)
        }
    }

    @Test func aStateGoogleMayAddLaterIsAnError() async throws {
        await #expect(throws: EntitlementError.unsupportedState("purchaseState 7")) {
            try await process(engine(RecordingPurchaseStore()), google(state: 7))
        }
    }

    @Test func anEmptyTokenOrProductIsAnError() async throws {
        let engine = engine(RecordingPurchaseStore())
        await #expect(throws: EntitlementError.missingTransactionID) {
            try await process(engine, google(), token: "")
        }
        await #expect(throws: EntitlementError.missingProductID) {
            try await process(engine, google(), product: "")
        }
    }

    @Test func aProductThatIsNotSoldIsIgnored() async throws {
        let store = RecordingPurchaseStore()
        let result = try await process(engine(store), google(), product: "other")
        #expect(result.outcome == .ignored)
        #expect(store.saved.isEmpty)
    }

    @Test func onlyAPaidUnacknowledgedPurchaseNeedsAcknowledgement() {
        #expect(google(state: 0, acknowledged: 0).needsAcknowledgement)
        #expect(!google(state: 0, acknowledged: 1).needsAcknowledgement)
        #expect(!google(state: 2, acknowledged: 0).needsAcknowledgement)
        #expect(!google(state: 1, acknowledged: 0).needsAcknowledgement)
    }

    @Test func theResponseOfProductsGetDecodes() throws {
        let json = """
            {"kind":"androidpublisher#productPurchase","purchaseTimeMillis":"1800000000000","purchaseState":0,
             "consumptionState":0,"orderId":"GPA.1","purchaseType":0,"acknowledgementState":0,
             "quantity":2,"refundableQuantity":2,"regionCode":"US"}
            """
        let purchase = try JSONDecoder().decode(GooglePlayProductPurchase.self, from: Data(json.utf8))
        #expect(purchase.purchaseState == 0)
        #expect(purchase.quantity == 2)
        #expect(purchase.orderId == "GPA.1")
        #expect(purchase.isTestPurchase)
        #expect(purchase.needsAcknowledgement)
        #expect(!purchase.isConsumed)
    }
}

@Suite("One-time purchase rules shared by both stores")
struct OneTimePurchaseRuleTests {
    /// Both calls can read "no record" before either saves. The store refuses the second write,
    /// and that call throws, so the caller's webhook is retried and then finds the record.
    @Test func twoEventsForOnePurchaseCannotBothGrant() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        let outcomes = await withTaskGroup(of: PurchaseResult.Outcome?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await engine.processAppStoreTransaction(
                        notifier: RecordingNotifier(), transaction: apple("coins.100")).outcome
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.filter { $0 == .granted }.count == 1)
        #expect(store.saved.count == 1)
    }

    @Test func aProductListedTwiceKeepsItsFirstKind() async throws {
        let store = RecordingPurchaseStore()
        let engine = PurchaseEngine(
            storeDelegate: store,
            products: [unlock, OneTimeProduct(id: "pro.unlock", kind: .consumable)], now: { now })
        let result = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("pro.unlock", quantity: 3))
        #expect(result.quantityChange == 1)
    }

    @Test func aRecordSurvivesStorage() throws {
        let record = PurchaseRecord(
            transactionID: "tx", productID: "coins.100", store: .appStore, accountID: "a", orderID: "o",
            quantity: 3, purchasedAt: now, expiresAt: now.addingTimeInterval(10), revokedQuantity: 1,
            revokedAt: now, storeRevokedAt: now, reversedThrough: now, reinstatedAt: now,
            isTest: true, isFamilyShared: true, revision: 4, updatedAt: now)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(PurchaseRecord.self, from: data) == record)
    }

    @Test func everyPurchaseNotificationHasCopyAndItsOwnCollapseID() {
        for notification in [EntitlementNotification.purchased, .purchaseRefunded, .purchaseReinstated] {
            #expect(!EntitlementMessages.default.payload(for: notification).title.isEmpty)
        }
        #expect(EntitlementNotification.purchased.collapseID == "purchased")
        #expect(EntitlementNotification.purchaseRefunded.collapseID == "purchase-refunded")
        #expect(EntitlementNotification.purchaseReinstated.collapseID == "purchase-reinstated")
    }
}

@Suite("Refund reversals, restores and what the delegate is told")
struct OneTimePurchaseReviewTests {
    private let later = now.addingTimeInterval(3_600)

    @Test func aReversedRefundGivesTheUnitsBack() async throws {
        let store = RecordingPurchaseStore()
        let notifier = RecordingNotifier()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: notifier, transaction: apple("coins.100", quantity: 3))
        _ = try await engine.processAppStoreTransaction(
            notifier: notifier, transaction: apple("coins.100", quantity: 3, revoked: now))
        #expect(store.held == 0)

        let reversed = try await engine.processAppStoreRefundReversal(
            notifier: notifier, transaction: apple("coins.100", quantity: 3), signedDate: later)
        #expect(reversed.outcome == .reinstated)
        #expect(reversed.quantityChange == 3)
        #expect(store.held == 3)
        let record = try #require(store.record("tx-1"))
        #expect(!record.isRevoked && record.revokedAt == nil && record.storeRevokedAt == nil)
        #expect(record.reversedThrough == later)
        #expect(record.reinstatedAt == now)
        #expect(record.revision == 3)
        #expect(notifier.sent.map(\.notification) == [.purchased, .purchaseRefunded, .purchaseReinstated])
    }

    @Test func aReversalTwiceGivesBackOnce() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now))
        _ = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100"), signedDate: later)
        let again = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100"), signedDate: later)
        #expect(again.outcome == .unchanged)
        #expect(store.held == 1)
    }

    /// Apple can resend the refund after it was reversed. That is not a second refund.
    @Test func theOldRefundResentAfterItsReversalChangesNothing() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now))
        _ = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100"), signedDate: later)
        let resent = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now))
        #expect(resent.outcome == .unchanged)
        #expect(store.held == 1)

        let newRefund = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: later.addingTimeInterval(60)))
        #expect(newRefund.outcome == .revoked)
        #expect(store.held == 0)
    }

    /// A reversal signed before the refund in force belongs to an earlier refund.
    @Test func aReversalOlderThanTheRefundInForceIsIgnored() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now))
        let old = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100"), signedDate: now.addingTimeInterval(-10))
        #expect(old.outcome == .unchanged)
        #expect(store.held == 0)
    }

    @Test func aReversalOfAPurchaseThatWasNeverRefundedChangesNothing() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        let result = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100"), signedDate: later)
        #expect(result.outcome == .unchanged)
        #expect(store.held == 1)
    }

    /// The purchase was never seen, so the reversal is the first news of a purchase that stands.
    @Test func aReversalOfAnUnknownPurchaseGrantsIt() async throws {
        let store = RecordingPurchaseStore()
        let result = try await engine(store).processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 2), signedDate: later)
        #expect(result.outcome == .granted)
        #expect(store.held == 2)
    }

    @Test func aReversalCallWithATransactionStillRevokedStaysRevoked() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        let result = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now), signedDate: later)
        #expect(result.outcome == .revoked)
        #expect(store.held == 0)
    }

    /// A restored copy has a new transaction ID and the original's ID. It is the same purchase.
    @Test func aRestoredNonConsumableIsOnePurchase() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("pro.unlock", id: "tx-1", original: "tx-1"))
        let restore = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("pro.unlock", id: "tx-2", original: "tx-1"))
        #expect(restore.outcome == .unchanged)
        #expect(store.held == 1)
        let refund = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("pro.unlock", id: "tx-1", original: "tx-1", revoked: now))
        #expect(refund.outcome == .revoked)
        #expect(store.held == 0)
        #expect(store.record("tx-2") == nil)
    }

    /// The delegate is handed each change with the save, so it can apply both in one transaction.
    @Test func everyChangeReachesTheDelegateWithItsSave() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        let events: [AppStoreTransaction] = [
            apple("coins.100", quantity: 3), apple("coins.100", quantity: 3),
            apple("coins.100", quantity: 3, revoked: now), apple("coins.100", quantity: 3, revoked: now),
            apple("coins.100", quantity: 3),
        ]
        var reported = 0
        for event in events {
            reported += try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: event)
                .quantityChange
        }
        #expect(store.held == 0)
        #expect(reported == store.held)
        #expect(store.saved.map(\.revision) == [1, 2])
        #expect(store.saved.last?.updatedAt == now)
    }

    @Test func aRefundWithoutAQuantityTakesBackEveryUnit() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 4))
        let refund = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now))
        #expect(refund.quantityChange == -4)
        #expect(store.held == 0)
    }

    @Test func twoRefundsAtOnceTakeBackOnce() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 2))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await engine.processAppStoreTransaction(
                        notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 2, revoked: now))
                }
            }
        }
        #expect(store.held == 0)
        #expect(store.saved.count == 2)
    }

    @Test func theRecordKeepsWhoseAppStorePurchaseItIs() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        var transaction = apple("pro.unlock")
        transaction.appAccountToken = "token-uuid"
        transaction.inAppOwnershipType = "FAMILY_SHARED"
        transaction.environment = "Sandbox"
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: transaction)
        let record = try #require(store.record("tx-1"))
        #expect(record.store == .appStore && record.accountID == "token-uuid")
        #expect(record.isFamilyShared && record.isTest)
        transaction.environment = "Production"
        transaction.transactionId = "tx-8"
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: transaction)
        #expect(store.record("tx-8")?.isTest == false)

        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("pro.unlock", id: "tx-9"), accountID: "mine")
        #expect(store.record("tx-9")?.accountID == "mine")
        #expect(store.record("tx-9")?.isTest == false)
    }

    @Test func thePushLastsADay() async throws {
        let notifier = RecordingNotifier()
        _ = try await engine(RecordingPurchaseStore()).processAppStoreTransaction(
            notifier: notifier, transaction: apple("coins.100"))
        #expect(notifier.sent.first?.expiresAt == now.addingTimeInterval(86_400))
    }

    @Test func aPendingResultStillNamesTheProduct() async throws {
        let result = try await engine(RecordingPurchaseStore()).processGooglePlayPurchase(
            notifier: RecordingNotifier(), productID: "coins.100", purchaseToken: "t", purchase: google(state: 2))
        #expect(result.product == coins)
        #expect(result.record == nil)
    }

    @Test func anEmptyProductIDIsNeverAProduct() async throws {
        let engine = PurchaseEngine(
            storeDelegate: RecordingPurchaseStore(), products: [OneTimeProduct(id: "", kind: .consumable)], now: { now })
        await #expect(throws: EntitlementError.missingProductID) {
            try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple(""))
        }
    }

    /// Subscriptions never read these fields, so an odd value in one must not fail the event.
    @Test func aSubscriptionPayloadDecodesWhenAOneTimeFieldHasAnotherShape() throws {
        let json = #"{"productId":"monthly","quantity":3000000000,"purchaseDate":"soon","type":7}"#
        let transaction = try JSONDecoder().decode(AppStoreTransaction.self, from: Data(json.utf8))
        #expect(transaction.productId == "monthly")
        #expect(transaction.quantity == nil && transaction.purchaseDate == nil && transaction.type == nil)
    }
}

@Suite("Out-of-order refunds, partial refunds and whose purchase it is")
struct OneTimePurchaseSecondReviewTests {
    private enum Event: CaseIterable {
        case purchase, refund1, reversal1, refund2, reversal2

        /// The date a refund carries, or the date a reversal was signed.
        var date: Date? {
            switch self {
            case .purchase: nil
            case .refund1: now.addingTimeInterval(100)
            case .reversal1: now.addingTimeInterval(200)
            case .refund2: now.addingTimeInterval(300)
            case .reversal2: now.addingTimeInterval(400)
            }
        }

        var isRefund: Bool { self == .refund1 || self == .refund2 }
        var isReversal: Bool { self == .reversal1 || self == .reversal2 }
    }

    /// Apple says to go by the notification signed last. So a refund stands only if no
    /// reversal signed after it has been seen, in whatever order they arrived.
    @Test(arguments: [("coins.100", Int32(3), 3), ("pro.unlock", Int32(1), 1), ("season.pass", Int32(1), 1)])
    func everyOrderOfAppleEventsEndsWithWhatTheLatestEventSays(product: String, quantity: Int32, units: Int) async throws {
        var sequences: [[Event]] = Event.allCases.map { [$0] }
        var all = sequences
        for _ in 1..<5 {
            sequences = sequences.flatMap { head in Event.allCases.map { head + [$0] } }
            all += sequences
        }
        var wrong: [String] = []
        for sequence in all {
            let store = RecordingPurchaseStore()
            let engine = engine(store)
            var reported = 0
            for event in sequence {
                let result: PurchaseResult
                if event.isReversal {
                    result = try await engine.processAppStoreRefundReversal(
                        notifier: RecordingNotifier(), transaction: apple(product, quantity: quantity),
                        signedDate: event.date!)
                } else {
                    result = try await engine.processAppStoreTransaction(
                        notifier: RecordingNotifier(),
                        transaction: apple(product, quantity: quantity, revoked: event.isRefund ? event.date : nil))
                }
                reported += result.quantityChange
            }
            let lastReversal = sequence.filter(\.isReversal).compactMap(\.date).max() ?? .distantPast
            let refundStands = sequence.contains { $0.isRefund && $0.date! > lastReversal }
            let expected = refundStands ? 0 : units
            if store.held != expected || reported != expected || store.record("tx-1")?.remainingQuantity != expected {
                wrong.append("\(sequence) holds \(store.held), expected \(expected)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) of \(all.count) wrong, first: \(wrong.prefix(3))")
    }

    @Test func aReversalThatOvertakesItsRefundIsRemembered() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        let early = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100"), signedDate: now.addingTimeInterval(200))
        #expect(early.outcome == .unchanged)
        #expect(early.didSave)
        #expect(early.notification == nil)
        #expect(store.record("tx-1")?.reversedThrough == now.addingTimeInterval(200))
        let late = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now.addingTimeInterval(100)))
        #expect(late.outcome == .unchanged)
        #expect(store.held == 1)
    }

    /// The reversal of the first refund must not undo the second.
    @Test func theReversalOfAnOlderRefundLeavesANewerOneInForce() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        for date in [now.addingTimeInterval(100), now.addingTimeInterval(300)] {
            _ = try await engine.processAppStoreTransaction(
                notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: date))
        }
        #expect(store.record("tx-1")?.storeRevokedAt == now.addingTimeInterval(300))
        let result = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100"), signedDate: now.addingTimeInterval(200))
        #expect(result.outcome == .unchanged)
        #expect(store.held == 0)
    }

    @Test func aReversalSignedAtTheRefundsOwnDateIsNotItsReversal() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", revoked: now))
        let tie = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100"), signedDate: now)
        #expect(tie.outcome == .unchanged)
    }

    /// A purchase first seen refunded keeps the refund's date, so its reversal is recognised.
    @Test func aPurchaseFirstSeenRefundedCanStillBeReversed() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 2, revoked: now.addingTimeInterval(100)))
        #expect(store.record("tx-1")?.storeRevokedAt == now.addingTimeInterval(100))
        let stale = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 2), signedDate: now)
        #expect(stale.outcome == .unchanged)
        let reversed = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 2),
            signedDate: now.addingTimeInterval(200))
        #expect(reversed.outcome == .reinstated)
        #expect(store.held == 2)
    }

    @Test func aReversalForAnotherProductsRecordIsAnError() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        await #expect(throws: EntitlementError.transactionMismatch) {
            try await engine.processAppStoreRefundReversal(
                notifier: RecordingNotifier(), transaction: apple("pro.unlock"), signedDate: now)
        }
    }

    private func prorated(_ part: Int64, quantity: Int32 = 3, product: String = "coins.100") -> AppStoreTransaction {
        var transaction = apple(product, quantity: quantity, revoked: now.addingTimeInterval(100))
        transaction.revocationType = "REFUND_PRORATED"
        transaction.revocationPercentage = part
        return transaction
    }

    /// Apple reports the refunded part in thousandths of a percent: one of three is 33333.
    @Test func aProratedRefundTakesBackItsShareOfAConsumable() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 3))
        let refund = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: prorated(33_333))
        #expect(refund.outcome == .revoked)
        #expect(refund.quantityChange == -1)
        #expect(store.held == 2)

        let reversed = try await engine.processAppStoreRefundReversal(
            notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 3),
            signedDate: now.addingTimeInterval(200))
        #expect(reversed.quantityChange == 1)
        #expect(store.held == 3)
    }

    @Test func aProratedRefundOfEverythingTakesEverything() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 3))
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: prorated(100_000))
        #expect(store.held == 0)
    }

    /// Part of the price back does not take away something that cannot be split.
    @Test func aProratedRefundLeavesANonConsumable() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("pro.unlock"))
        let refund = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: prorated(40_000, quantity: 1, product: "pro.unlock"))
        #expect(refund.outcome == .unchanged)
        #expect(store.held == 1)
    }

    @Test func aProratedRefundWithoutItsPercentageIsAnError() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 3))
        var refund = apple("coins.100", quantity: 3, revoked: now)
        refund.revocationType = "REFUND_PRORATED"
        await #expect(throws: EntitlementError.unsupportedState("REFUND_PRORATED without revocationPercentage")) {
            try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: refund)
        }
        #expect(store.held == 3)
    }

    @Test func onlyAKnownTestEnvironmentMarksATestPurchase() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        for (index, environment) in ["Sandbox", "Xcode", "LocalTesting", "Production", "Something"].enumerated() {
            var transaction = apple("coins.100", id: "e-\(index)")
            transaction.environment = environment
            _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: transaction)
            #expect(store.record("e-\(index)")?.isTest == (index < 3))
        }
        _ = try await engine.processGooglePlayPurchase(
            notifier: RecordingNotifier(), productID: "coins.100", purchaseToken: "g", purchase: google())
        #expect(store.record("g")?.isFamilyShared == false && store.record("g")?.isTest == false)
    }

    @Test func aFullRefundIgnoresAStrayPercentage() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100", quantity: 3))
        var refund = prorated(33_333)
        refund.revocationType = "REFUND_FULL"
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: refund)
        #expect(store.held == 0)
    }

    /// Units have to be granted to someone. Nothing is saved, so the buyer's own call grants it.
    @Test func aPurchaseThatNamesNobodyIsAnError() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        var anonymous = apple("coins.100", quantity: 3)
        anonymous.appAccountToken = nil
        await #expect(throws: EntitlementError.missingAccountID) {
            try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: anonymous)
        }
        anonymous.appAccountToken = ""
        await #expect(throws: EntitlementError.missingAccountID) {
            try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: anonymous)
        }
        #expect(store.saved.isEmpty)

        let mine = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: anonymous, accountID: "user-1")
        #expect(mine.outcome == .granted)
        #expect(store.record("tx-1")?.accountID == "user-1")

        var google = google()
        google.obfuscatedExternalAccountId = nil
        await #expect(throws: EntitlementError.missingAccountID) {
            try await engine.processGooglePlayPurchase(
                notifier: RecordingNotifier(), productID: "coins.100", purchaseToken: "t", purchase: google)
        }
    }

    /// A refund first seen with no buyer is still recorded, or the late purchase would be granted.
    @Test func aRefundThatNamesNobodyIsStillRecorded() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        var refund = apple("coins.100", revoked: now)
        refund.appAccountToken = nil
        let result = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: refund)
        #expect(result.outcome == .revoked)
        let late = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("coins.100"), accountID: "user-1")
        #expect(late.outcome == .unchanged)
        #expect(store.held == 0)
    }

    /// A later event for a known purchase does not need to name the buyer again.
    @Test func aRefundOfAKnownPurchaseNeedsNoAccount() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: apple("coins.100"))
        var refund = apple("coins.100", revoked: now)
        refund.appAccountToken = nil
        let result = try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: refund)
        #expect(result.outcome == .revoked)
        #expect(result.record?.accountID == "buyer")
    }

    /// If family copies ever share the buyer's original ID, a member leaving must not take the
    /// buyer's purchase.
    @Test func aFamilyCopyNeverTouchesThePaidPurchase() async throws {
        let store = RecordingPurchaseStore()
        let engine = engine(store)
        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: apple("pro.unlock", id: "tx-1", original: "tx-1"))
        var member = apple("pro.unlock", id: "tx-5", original: "tx-1", revoked: now)
        member.inAppOwnershipType = "FAMILY_SHARED"
        member.revocationType = "FAMILY_REVOKE"
        await #expect(throws: EntitlementError.transactionMismatch) {
            try await engine.processAppStoreTransaction(notifier: RecordingNotifier(), transaction: member)
        }
        #expect(store.held == 1)
    }

    @Test func aRecordSavedByAnEarlierVersionStillDecodes() throws {
        let json = #"{"transactionID":"t","productID":"p","store":"app-store","quantity":2,"purchasedAt":0,"updatedAt":0}"#
        let record = try JSONDecoder().decode(PurchaseRecord.self, from: Data(json.utf8))
        #expect(record.quantity == 2 && record.revokedQuantity == 0 && record.revision == 1)
        #expect(!record.isTest && !record.isFamilyShared && record.accountID == nil)
    }

    @Test func theTransactionDecodesTheRevocationFields() throws {
        let json = #"{"productId":"c","revocationType":"REFUND_PRORATED","revocationPercentage":33333,"signedDate":1800000000000}"#
        let transaction = try JSONDecoder().decode(AppStoreTransaction.self, from: Data(json.utf8))
        #expect(transaction.revocationType == "REFUND_PRORATED")
        #expect(transaction.revocationPercentage == 33_333)
        #expect(transaction.signedDate == now)
    }
}
