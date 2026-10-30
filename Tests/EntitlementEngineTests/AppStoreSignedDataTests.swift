import Foundation
import Testing
@testable import IAPEntitlementEngine

@Suite("App Store signed data mapping")
struct AppStoreSignedDataAdapterTests {
    let future = now.addingTimeInterval(86_400 * 30)
    let past = now.addingTimeInterval(-86_400)

    func map(
        _ transaction: AppStoreTransaction,
        _ renewal: AppStoreRenewalInfo = AppStoreRenewalInfo(autoRenewStatus: 1)
    ) throws -> SubscriptionSnapshot {
        try AppStoreSignedDataAdapter.snapshot(transaction: transaction, renewalInfo: renewal, now: now)
    }

    @Test func emptyProductIsNotSubscribed() throws {
        #expect(try map(AppStoreTransaction()).lifecycle == .notSubscribed)
        #expect(try map(AppStoreTransaction(productId: "")).lifecycle == .notSubscribed)
    }

    @Test func activeTransactionMaps() throws {
        let snapshot = try map(AppStoreTransaction(productId: "monthly", expiresDate: future))
        #expect(snapshot.productID == "monthly")
        #expect(snapshot.lifecycle == .active)
        #expect(snapshot.autoRenewEnabled)
        #expect(snapshot.offer == .none)
        #expect(snapshot.expiresAt == future)
    }

    @Test(arguments: [Int32(0), 7])
    func autoRenewIsOnOnlyForStatusOne(status: Int32) throws {
        let snapshot = try map(
            AppStoreTransaction(productId: "monthly", expiresDate: future),
            AppStoreRenewalInfo(autoRenewStatus: status))
        #expect(!snapshot.autoRenewEnabled)
    }

    @Test func missingAutoRenewStatusIsOff() throws {
        let snapshot = try map(
            AppStoreTransaction(productId: "monthly", expiresDate: future),
            AppStoreRenewalInfo())
        #expect(!snapshot.autoRenewEnabled)
    }

    @Test func introductoryFreeTrialIsATrial() throws {
        let snapshot = try map(AppStoreTransaction(
            productId: "monthly", expiresDate: future, offerType: 1, offerDiscountType: "FREE_TRIAL"))
        #expect(snapshot.offer == .trial)
    }

    @Test(arguments: ["PAY_AS_YOU_GO", "PAY_UP_FRONT"])
    func paidIntroductoryOfferIsIntro(discount: String) throws {
        let snapshot = try map(AppStoreTransaction(
            productId: "monthly", expiresDate: future, offerType: 1, offerDiscountType: discount))
        #expect(snapshot.offer == .introductory)
    }

    /// `offerDiscountType` is newer than `offerType`, so older transactions only carry the type.
    @Test func introductoryOfferWithoutADiscountTypeIsIntro() throws {
        let snapshot = try map(AppStoreTransaction(productId: "monthly", expiresDate: future, offerType: 1))
        #expect(snapshot.offer == .introductory)
    }

    /// A free promotional offer or offer code is still a free period, so "free trial" is the right copy.
    @Test(arguments: [Int32(2), 3, 4])
    func freeNonIntroductoryOfferIsATrial(offerType: Int32) throws {
        let snapshot = try map(AppStoreTransaction(
            productId: "monthly", expiresDate: future, offerType: offerType, offerDiscountType: "FREE_TRIAL"))
        #expect(snapshot.offer == .trial)
    }

    /// Receipts report neither flag for these, so the copy stays the same across both paths.
    @Test(arguments: [Int32(2), 3, 4])
    func paidNonIntroductoryOfferIsNoOffer(offerType: Int32) throws {
        let snapshot = try map(AppStoreTransaction(
            productId: "monthly", expiresDate: future, offerType: offerType, offerDiscountType: "PAY_AS_YOU_GO"))
        #expect(snapshot.offer == .none)
    }

    @Test func revocationDateIsRevoked() throws {
        let snapshot = try map(AppStoreTransaction(
            productId: "monthly", expiresDate: future, revocationDate: past, revocationReason: 0))
        #expect(snapshot.lifecycle == .revoked(.other))
        #expect(snapshot.expiresAt == nil)
    }

    @Test func revocationReasonOneIsAnAppIssue() throws {
        let snapshot = try map(AppStoreTransaction(
            productId: "monthly", expiresDate: future, revocationDate: past, revocationReason: 1))
        #expect(snapshot.lifecycle == .revoked(.appIssue))
    }

    /// Family Sharing removals have a date but no reason, and access still has to end.
    @Test func revocationWithoutAReasonIsRevoked() throws {
        let snapshot = try map(AppStoreTransaction(productId: "monthly", expiresDate: future, revocationDate: past))
        #expect(snapshot.lifecycle == .revoked(.other))
    }

    @Test func revocationNeedsNoExpiryDate() throws {
        let snapshot = try map(AppStoreTransaction(productId: "monthly", revocationDate: past))
        #expect(snapshot.lifecycle == .revoked(.other))
    }

    /// An upgraded transaction carries a revocation date, but the user kept their access.
    @Test func upgradeWinsOverItsRevocationDate() throws {
        let snapshot = try map(AppStoreTransaction(
            productId: "monthly", expiresDate: future, isUpgraded: true, revocationDate: past))
        #expect(snapshot.lifecycle == .upgraded)
    }

    @Test func isUpgradedFalseIsNotAnUpgrade() throws {
        let snapshot = try map(AppStoreTransaction(productId: "monthly", expiresDate: future, isUpgraded: false))
        #expect(snapshot.lifecycle == .active)
    }

    @Test func graceDateAppliesOnlyAfterExpiry() throws {
        let grace = now.addingTimeInterval(86_400 * 3)
        let renewal = AppStoreRenewalInfo(autoRenewStatus: 1, gracePeriodExpiresDate: grace)

        let lapsed = try map(AppStoreTransaction(productId: "monthly", expiresDate: past), renewal)
        #expect(lapsed.lifecycle == .gracePeriod)
        #expect(lapsed.expiresAt == grace)

        let current = try map(AppStoreTransaction(productId: "monthly", expiresDate: future), renewal)
        #expect(current.lifecycle == .active)
        #expect(current.expiresAt == future)
    }

    @Test func expiryExactlyNowHasLapsed() throws {
        let grace = now.addingTimeInterval(60)
        let snapshot = try map(
            AppStoreTransaction(productId: "monthly", expiresDate: now),
            AppStoreRenewalInfo(gracePeriodExpiresDate: grace))
        #expect(snapshot.lifecycle == .gracePeriod)
    }

    @Test func billingRetryAfterExpiryIsSuspended() throws {
        let snapshot = try map(
            AppStoreTransaction(productId: "monthly", expiresDate: past),
            AppStoreRenewalInfo(isInBillingRetryPeriod: true))
        #expect(snapshot.lifecycle == .suspended(.billing))
    }

    @Test func billingRetryBeforeExpiryChangesNothing() throws {
        let snapshot = try map(
            AppStoreTransaction(productId: "monthly", expiresDate: future),
            AppStoreRenewalInfo(isInBillingRetryPeriod: true))
        #expect(snapshot.lifecycle == .active)
    }

    /// Apple retries during a grace period too, and the customer keeps access until it ends.
    @Test func gracePeriodWinsOverBillingRetryUntilItEnds() throws {
        let running = try map(
            AppStoreTransaction(productId: "monthly", expiresDate: past),
            AppStoreRenewalInfo(gracePeriodExpiresDate: now.addingTimeInterval(60), isInBillingRetryPeriod: true))
        #expect(running.lifecycle == .gracePeriod)

        let ended = try map(
            AppStoreTransaction(productId: "monthly", expiresDate: past),
            AppStoreRenewalInfo(gracePeriodExpiresDate: now, isInBillingRetryPeriod: true))
        #expect(ended.lifecycle == .suspended(.billing))
    }

    @Test func revocationWinsOverBillingRetry() throws {
        let snapshot = try map(
            AppStoreTransaction(productId: "monthly", expiresDate: past, revocationDate: past),
            AppStoreRenewalInfo(isInBillingRetryPeriod: true))
        #expect(snapshot.lifecycle == .revoked(.other))
    }

    @Test func missingExpiryThrows() {
        #expect(throws: EntitlementError.invalidDate(field: "expiresDate")) {
            try map(AppStoreTransaction(productId: "monthly"))
        }
    }

    @Test func renewalInfoForAnotherSubscriptionIsRejected() {
        #expect(throws: EntitlementError.transactionMismatch) {
            try map(
                AppStoreTransaction(productId: "monthly", originalTransactionId: "1", expiresDate: future),
                AppStoreRenewalInfo(originalTransactionId: "2"))
        }
    }

    @Test func matchingOriginalTransactionsAreAccepted() throws {
        let snapshot = try map(
            AppStoreTransaction(productId: "monthly", originalTransactionId: "1", expiresDate: future),
            AppStoreRenewalInfo(originalTransactionId: "1"))
        #expect(snapshot.lifecycle == .active)
    }
}

/// The same situation expressed in both Apple formats has to reach the rules as the same snapshot.
@Suite("Receipt and signed data parity")
struct AppleParityTests {
    struct Scenario: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let receipt: LatestReceiptInfo
        let pending: PendingRenewalInfo
        let transaction: AppStoreTransaction
        let renewal: AppStoreRenewalInfo
    }

    static let future = now.addingTimeInterval(86_400 * 30)
    static let soon = now.addingTimeInterval(3_600)
    static let past = now.addingTimeInterval(-86_400)
    static let grace = now.addingTimeInterval(86_400 * 3)

    static func scenario(
        _ name: String,
        expires: Date,
        autoRenew: Bool = true,
        graceUntil: Date? = nil,
        retrying: Bool = false,
        revoked: Date? = nil,
        reason: Int32? = nil,
        upgraded: Bool = false,
        trial: Bool = false,
        intro: Bool = false
    ) -> Scenario {
        Scenario(
            testDescription: name,
            receipt: LatestReceiptInfo(
                productId: "monthly",
                originalTransactionId: "1",
                expiresDateMs: milliseconds(expires),
                isTrialPeriod: trial ? "true" : "false",
                isInIntroOfferPeriod: intro ? "true" : "false",
                cancellationDateMs: revoked.map(milliseconds),
                cancellationReason: reason.map(String.init),
                isUpgraded: upgraded ? "true" : nil),
            pending: PendingRenewalInfo(
                originalTransactionId: "1",
                autoRenewStatus: autoRenew ? "1" : "0",
                gracePeriodExpiresDateMs: graceUntil.map(milliseconds),
                isInBillingRetryPeriod: retrying ? "1" : "0"),
            transaction: AppStoreTransaction(
                productId: "monthly",
                originalTransactionId: "1",
                expiresDate: expires,
                isUpgraded: upgraded ? true : nil,
                revocationDate: revoked,
                revocationReason: reason,
                offerType: trial || intro ? 1 : nil,
                offerDiscountType: trial ? "FREE_TRIAL" : intro ? "PAY_AS_YOU_GO" : nil),
            renewal: AppStoreRenewalInfo(
                originalTransactionId: "1",
                autoRenewStatus: autoRenew ? 1 : 0,
                gracePeriodExpiresDate: graceUntil,
                isInBillingRetryPeriod: retrying))
    }

    static let scenarios = [
        scenario("active", expires: future),
        scenario("auto-renew off", expires: future, autoRenew: false),
        scenario("expiring today", expires: soon, autoRenew: false),
        scenario("lapsed", expires: past),
        scenario("trial", expires: future, trial: true),
        scenario("intro offer", expires: future, intro: true),
        scenario("grace period", expires: past, graceUntil: grace),
        scenario("grace period ended", expires: past.addingTimeInterval(-86_400), graceUntil: past),
        scenario("grace date while active", expires: future, graceUntil: grace),
        scenario("billing retry", expires: past, retrying: true),
        scenario("billing retry while active", expires: future, retrying: true),
        scenario("billing retry in grace", expires: past, graceUntil: grace, retrying: true),
        scenario("billing retry after grace", expires: past.addingTimeInterval(-86_400), graceUntil: past, retrying: true),
        scenario("billing retry on a refund", expires: past, retrying: true, revoked: past, reason: 0),
        scenario("refund", expires: future, revoked: past, reason: 0),
        scenario("refund for an app issue", expires: future, revoked: past, reason: 1),
        scenario("upgraded", expires: future, revoked: past, upgraded: true),
    ]

    @Test(arguments: scenarios)
    func bothFormatsProduceTheSameSnapshot(_ scenario: Scenario) throws {
        let receipt = try AppleReceiptAdapter.snapshot(
            latestReceiptInfo: scenario.receipt, pendingRenewalInfo: scenario.pending, now: now)
        let signed = try AppStoreSignedDataAdapter.snapshot(
            transaction: scenario.transaction, renewalInfo: scenario.renewal, now: now)
        #expect(signed == receipt)
    }

    @Test(arguments: scenarios, [true, false])
    func bothFormatsReachTheSameDecision(_ scenario: Scenario, wasSubscribed: Bool) throws {
        let evaluator = EntitlementEvaluator(catalog: catalog)
        let order = Order(id: orderID, productName: "monthly", isSubscribed: wasSubscribed)
        let receipt = try AppleReceiptAdapter.snapshot(
            latestReceiptInfo: scenario.receipt, pendingRenewalInfo: scenario.pending, now: now)
        let signed = try AppStoreSignedDataAdapter.snapshot(
            transaction: scenario.transaction, renewalInfo: scenario.renewal, now: now)
        #expect(evaluator.evaluate(signed, order: order, now: now)
            == evaluator.evaluate(receipt, order: order, now: now))
    }
}

@Suite("App Store signed data decoding")
struct AppStoreSignedDataDecodingTests {
    /// Trimmed from Apple's `signedTransaction.json` test fixture, values adjusted.
    static let transactionJSON = #"""
    {"transactionId":"23456","originalTransactionId":"12345","webOrderLineItemId":"34343",
     "bundleId":"com.example","productId":"monthly","subscriptionGroupIdentifier":"55555",
     "purchaseDate":1798148900000,"originalPurchaseDate":1798148800000,"expiresDate":1800000000123,
     "quantity":1,"type":"Auto-Renewable Subscription","inAppOwnershipType":"PURCHASED",
     "signedDate":1798148900000,"revocationReason":1,"revocationDate":1799000000456,"isUpgraded":true,
     "offerType":1,"offerIdentifier":"abc.123","environment":"LocalTesting","transactionReason":"PURCHASE",
     "storefront":"USA","storefrontId":"143441","price":10990,"currency":"USD",
     "offerDiscountType":"FREE_TRIAL","appTransactionId":"71134","offerPeriod":"P1Y"}
    """#

    /// Trimmed from Apple's `signedRenewalInfo.json` test fixture, values adjusted.
    static let renewalJSON = #"""
    {"expirationIntent":1,"originalTransactionId":"12345","autoRenewProductId":"yearly",
     "productId":"monthly","autoRenewStatus":1,"isInBillingRetryPeriod":true,"priceIncreaseStatus":0,
     "gracePeriodExpiresDate":1800000000789,"offerType":2,"offerIdentifier":"abc.123",
     "signedDate":1798148800000,"environment":"LocalTesting","recentSubscriptionStartDate":1798148800000,
     "renewalDate":1798148850000,"renewalPrice":9990,"currency":"USD","offerDiscountType":"PAY_AS_YOU_GO"}
    """#

    @Test func decodesARealTransactionShape() throws {
        let transaction = try JSONDecoder().decode(AppStoreTransaction.self, from: Data(Self.transactionJSON.utf8))
        #expect(transaction == AppStoreTransaction(
            productId: "monthly",
            originalTransactionId: "12345",
            expiresDate: Date(milliseconds: 1_800_000_000_123),
            isUpgraded: true,
            revocationDate: Date(milliseconds: 1_799_000_000_456),
            revocationReason: 1,
            offerType: 1,
            offerDiscountType: "FREE_TRIAL"))
    }

    @Test func decodesARealRenewalShape() throws {
        let renewal = try JSONDecoder().decode(AppStoreRenewalInfo.self, from: Data(Self.renewalJSON.utf8))
        #expect(renewal == AppStoreRenewalInfo(
            originalTransactionId: "12345",
            autoRenewStatus: 1,
            gracePeriodExpiresDate: Date(milliseconds: 1_800_000_000_789),
            isInBillingRetryPeriod: true))
    }

    /// Foundation's default strategy reads a number as seconds since 2001, which would turn a
    /// millisecond expiry into a date tens of thousands of years away and grant access for good.
    @Test(arguments: [JSONDecoder.DateDecodingStrategy.deferredToDate, .millisecondsSince1970, .secondsSince1970])
    func datesAreMillisecondsWhateverTheDecoderSays(strategy: JSONDecoder.DateDecodingStrategy) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = strategy
        let transaction = try decoder.decode(
            AppStoreTransaction.self, from: Data(#"{"expiresDate":1800000000000}"#.utf8))
        #expect(transaction.expiresDate == now)
        let renewal = try decoder.decode(
            AppStoreRenewalInfo.self, from: Data(#"{"gracePeriodExpiresDate":1800000000000}"#.utf8))
        #expect(renewal.gracePeriodExpiresDate == now)
    }

    @Test(arguments: ["expiresDate", "revocationDate"])
    func malformedTransactionDateThrowsInsteadOfFailingOpen(field: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppStoreTransaction.self, from: Data(#"{"\#(field)":"soon"}"#.utf8))
        }
    }

    @Test func malformedGraceDateThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AppStoreRenewalInfo.self, from: Data(#"{"gracePeriodExpiresDate":"soon"}"#.utf8))
        }
    }

    @Test func absentFieldsDecodeToNil() throws {
        let transaction = try JSONDecoder().decode(AppStoreTransaction.self, from: Data("{}".utf8))
        #expect(transaction == AppStoreTransaction())
        let renewal = try JSONDecoder().decode(AppStoreRenewalInfo.self, from: Data("{}".utf8))
        #expect(renewal == AppStoreRenewalInfo())
    }
}

@Suite("App Store signed data engine flow")
struct AppStoreSignedDataEngineTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()
    let future = now.addingTimeInterval(86_400 * 30)
    let active = AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(86_400 * 30))
    let renewing = AppStoreRenewalInfo(autoRenewStatus: 1)

    func engine(store: RecordingStore? = nil) -> EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store ?? self.store,
            weeklyProductID: "weekly",
            monthlyProductID: "monthly",
            yearlyProductID: "yearly",
            now: { now })
    }

    func order(subscribed: Bool, product: String? = "monthly") -> Order {
        Order(id: orderID, productName: product, isSubscribed: subscribed)
    }

    @Test func activeSubscriberIsNeverToldTheyCancelled() async throws {
        _ = try await engine().processAppStoreTransaction(
            notifier: notifier, order: order(subscribed: true), orderId: orderID.uuidString,
            transaction: active, renewalInfo: renewing)
        #expect(notifier.sent.isEmpty)
        #expect(store.updates.isEmpty)
    }

    @Test func newSubscriberIsSavedThenWelcomed() async throws {
        let status = try await engine().processAppStoreTransaction(
            notifier: notifier, order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
            transaction: active, renewalInfo: renewing)

        #expect(status == .ok)
        #expect(store.updates.first?.order.isSubscribed == true)
        #expect(store.updates.first?.order.productName == "monthly")
        #expect(notifier.sent.map(\.collapseID) == ["monthly-active"])
    }

    @Test func refundRevokesThenNotifies() async throws {
        let status = try await engine().processAppStoreTransaction(
            notifier: notifier, order: order(subscribed: true), orderId: orderID.uuidString,
            transaction: AppStoreTransaction(
                productId: "monthly", expiresDate: future,
                revocationDate: now.addingTimeInterval(-60), revocationReason: 0),
            renewalInfo: AppStoreRenewalInfo())

        #expect(status == .ok)
        #expect(store.updates.count == 1)
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(store.updates.first?.order.updatedAt == now)
        #expect(store.updates.first?.id == orderID)
        #expect(notifier.sent.map(\.collapseID) == ["cancelled"])
    }

    @Test func billingRetryEndsAccessAndAsksForPaymentOnce() async throws {
        let lapsed = AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(-60))
        let retrying = AppStoreRenewalInfo(autoRenewStatus: 1, isInBillingRetryPeriod: true)
        _ = try await engine().processAppStoreTransaction(
            notifier: notifier, order: order(subscribed: true), orderId: orderID.uuidString,
            transaction: lapsed, renewalInfo: retrying)
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.map(\.collapseID) == ["billing-issue"])

        let saved = try #require(store.updates.first?.order)
        _ = try await engine().processAppStoreTransaction(
            notifier: notifier, order: saved, orderId: orderID.uuidString,
            transaction: lapsed, renewalInfo: retrying)
        #expect(notifier.sent.count == 1)
    }

    @Test func pushExpiryIsInTheFuture() async throws {
        _ = try await engine().processAppStoreTransaction(
            notifier: notifier, order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
            transaction: active, renewalInfo: renewing)
        #expect(notifier.sent.first?.expiresAt == now.addingTimeInterval(86_400))
    }

    /// Unlike `processReceipt`, the destination lives in the notifier, not in the engine.
    @Test func worksThroughAPNsOnAnEngineWithoutAPNsConfiguration() async throws {
        let client = FakeAPNSClient()
        _ = try await engine().processAppStoreTransaction(
            notifier: APNSEntitlementNotifier(client: client, topic: "com.example.app", deviceToken: "abcd"),
            order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
            transaction: active, renewalInfo: renewing)

        let request = try #require(client.requests.first)
        #expect(request.deviceToken == "abcd")
        #expect(request.topic == "com.example.app")
        #expect(request.collapseID == "monthly-active")
    }

    @Test func invalidOrderIDThrows() async {
        await #expect(throws: EntitlementError.invalidOrderID) {
            _ = try await engine().processAppStoreTransaction(
                notifier: notifier, order: order(subscribed: true), orderId: "not-a-uuid",
                transaction: active, renewalInfo: renewing)
        }
    }

    @Test func untrustworthyPayloadsChangeNothing() async {
        let order = order(subscribed: true)
        await #expect(throws: EntitlementError.invalidDate(field: "expiresDate")) {
            _ = try await engine().processAppStoreTransaction(
                notifier: notifier, order: order, orderId: orderID.uuidString,
                transaction: AppStoreTransaction(productId: "monthly"), renewalInfo: renewing)
        }
        await #expect(throws: EntitlementError.transactionMismatch) {
            _ = try await engine().processAppStoreTransaction(
                notifier: notifier, order: order, orderId: orderID.uuidString,
                transaction: AppStoreTransaction(
                    productId: "monthly", originalTransactionId: "1", expiresDate: future),
                renewalInfo: AppStoreRenewalInfo(originalTransactionId: "2"))
        }
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    @Test func storeFailurePropagatesAndNoPushIsSent() async {
        let failing = RecordingStore(failure: TestFailure.boom)
        await #expect(throws: TestFailure.boom) {
            _ = try await engine(store: failing).processAppStoreTransaction(
                notifier: notifier, order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
                transaction: active, renewalInfo: renewing)
        }
        #expect(notifier.sent.isEmpty)
    }

    @Test func pushFailurePropagatesAfterEntitlementIsSaved() async {
        let failing = RecordingNotifier(failure: TestFailure.boom)
        await #expect(throws: TestFailure.boom) {
            _ = try await engine().processAppStoreTransaction(
                notifier: failing, order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
                transaction: active, renewalInfo: renewing)
        }
        #expect(store.updates.count == 1)
    }

    @Test func concurrentCallsKeepTheirOwnOrders() async throws {
        let engine = engine()
        let ids = (0..<50).map { _ in UUID() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [notifier, active, renewing] in
                    _ = try await engine.processAppStoreTransaction(
                        notifier: notifier,
                        order: Order(id: id, isSubscribed: false),
                        orderId: id.uuidString,
                        transaction: active,
                        renewalInfo: renewing)
                }
            }
            try await group.waitForAll()
        }
        #expect(Set(store.updates.map(\.id)) == Set(ids))
        #expect(store.updates.allSatisfy { $0.id == $0.order.id })
    }

    @Test func clockIsReadPerCallNotAtInit() async throws {
        let clock = TestClock(now)
        let engine = EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { clock.value })
        clock.value = now.addingTimeInterval(86_400 * 31)
        _ = try await engine.processAppStoreTransaction(
            notifier: notifier, order: order(subscribed: true), orderId: orderID.uuidString,
            transaction: active, renewalInfo: renewing)
        #expect(store.updates.first?.order.isSubscribed == false)
    }
}
