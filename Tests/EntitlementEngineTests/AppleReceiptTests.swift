import APNS
import Foundation
import Testing
@testable import IAPEntitlementEngine

@Suite("Apple receipt mapping")
struct AppleReceiptAdapterTests {
    let future = milliseconds(now.addingTimeInterval(86_400 * 30))
    let past = milliseconds(now.addingTimeInterval(-86_400))

    func map(
        _ receipt: LatestReceiptInfo,
        _ renewal: PendingRenewalInfo = PendingRenewalInfo(autoRenewStatus: "1")
    ) throws -> SubscriptionSnapshot {
        try AppleReceiptAdapter.snapshot(latestReceiptInfo: receipt, pendingRenewalInfo: renewal, now: now)
    }

    @Test func emptyProductIsNotSubscribed() throws {
        #expect(try map(LatestReceiptInfo()).lifecycle == .notSubscribed)
    }

    @Test func activeReceiptMaps() throws {
        let snapshot = try map(LatestReceiptInfo(productId: "monthly", expiresDateMs: future))
        #expect(snapshot.lifecycle == .active)
        #expect(snapshot.autoRenewEnabled)
        #expect(snapshot.offer == .none)
        #expect(snapshot.expiresAt == Date(milliseconds: Int64(future)!))
    }

    @Test func autoRenewStatusZeroIsOff() throws {
        let snapshot = try map(
            LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
            PendingRenewalInfo(autoRenewStatus: "0"))
        #expect(!snapshot.autoRenewEnabled)
    }

    /// Apple sends both flags. `"false"` on one must not mask `"true"` on the other.
    @Test func trialWithIntroFlagFalseIsATrial() throws {
        let snapshot = try map(LatestReceiptInfo(
            productId: "monthly", expiresDateMs: future,
            isTrialPeriod: "true", isInIntroOfferPeriod: "false"))
        #expect(snapshot.offer == .trial)
    }

    @Test func introWithTrialFlagFalseIsIntro() throws {
        let snapshot = try map(LatestReceiptInfo(
            productId: "monthly", expiresDateMs: future,
            isTrialPeriod: "false", isInIntroOfferPeriod: "true"))
        #expect(snapshot.offer == .introductory)
    }

    @Test func pastCancellationDateIsRevoked() throws {
        let snapshot = try map(LatestReceiptInfo(
            productId: "monthly", expiresDateMs: future, cancellationDateMs: past, cancellationReason: "0"))
        #expect(snapshot.lifecycle == .revoked(.other))
    }

    @Test func cancellationReasonOneIsAnAppIssue() throws {
        let snapshot = try map(LatestReceiptInfo(
            productId: "monthly", expiresDateMs: future, cancellationDateMs: past, cancellationReason: "1"))
        #expect(snapshot.lifecycle == .revoked(.appIssue))
    }

    @Test func emptyCancellationDateIsNotACancellation() throws {
        let snapshot = try map(LatestReceiptInfo(
            productId: "monthly", expiresDateMs: future, cancellationDateMs: ""))
        #expect(snapshot.lifecycle == .active)
    }

    /// An upgraded transaction carries a cancellation date, but the user kept their access.
    @Test func upgradeWinsOverItsCancellationDate() throws {
        let snapshot = try map(LatestReceiptInfo(
            productId: "monthly", expiresDateMs: future, cancellationDateMs: past, isUpgraded: "true"))
        #expect(snapshot.lifecycle == .upgraded)
    }

    @Test func graceDateAppliesOnlyAfterExpiry() throws {
        let grace = milliseconds(now.addingTimeInterval(86_400 * 3))
        let renewal = PendingRenewalInfo(autoRenewStatus: "1", gracePeriodExpiresDateMs: grace)

        let lapsed = try map(LatestReceiptInfo(productId: "monthly", expiresDateMs: past), renewal)
        #expect(lapsed.lifecycle == .gracePeriod)
        #expect(lapsed.expiresAt == Date(milliseconds: Int64(grace)!))

        let current = try map(LatestReceiptInfo(productId: "monthly", expiresDateMs: future), renewal)
        #expect(current.lifecycle == .active)
    }

    @Test func malformedExpiryThrowsInsteadOfFailingOpen() {
        #expect(throws: EntitlementError.invalidDate(field: "expires_date_ms")) {
            try map(LatestReceiptInfo(productId: "monthly", expiresDateMs: "soon"))
        }
    }

    @Test func missingExpiryThrows() {
        #expect(throws: EntitlementError.invalidDate(field: "expires_date_ms")) {
            try map(LatestReceiptInfo(productId: "monthly"))
        }
    }

    @Test func malformedCancellationDateThrows() {
        #expect(throws: EntitlementError.invalidDate(field: "cancellation_date_ms")) {
            try map(LatestReceiptInfo(productId: "monthly", expiresDateMs: future, cancellationDateMs: "x"))
        }
    }

    @Test func malformedGraceDateThrows() {
        #expect(throws: EntitlementError.invalidDate(field: "grace_period_expires_date_ms")) {
            try map(
                LatestReceiptInfo(productId: "monthly", expiresDateMs: past),
                PendingRenewalInfo(gracePeriodExpiresDateMs: "x"))
        }
    }

    @Test func renewalInfoForAnotherSubscriptionIsRejected() {
        #expect(throws: EntitlementError.transactionMismatch) {
            try map(
                LatestReceiptInfo(productId: "monthly", originalTransactionId: "1", expiresDateMs: future),
                PendingRenewalInfo(originalTransactionId: "2"))
        }
    }

    @Test func decodesARealReceiptShape() throws {
        let json = #"""
        {"quantity":"1","product_id":"monthly","transaction_id":"2","original_transaction_id":"1",
         "purchase_date":"x","purchase_date_ms":"1","purchase_date_pst":"x","original_purchase_date":"x",
         "original_purchase_date_ms":"1","original_purchase_date_pst":"x","expires_date":"x",
         "expires_date_ms":"1800000000000","expires_date_pst":"x","web_order_line_item_id":"3",
         "is_trial_period":"false","is_in_intro_offer_period":"false","subscription_group_identifier":"4",
         "in_app_ownership_type":"PURCHASED"}
        """#
        let receipt = try JSONDecoder().decode(LatestReceiptInfo.self, from: Data(json.utf8))
        #expect(receipt.productId == "monthly")
        #expect(receipt.expiresDateMs == "1800000000000")
    }
}

@Suite("Apple engine flow")
struct AppleEngineTests {
    let store = RecordingStore()
    let client = FakeAPNSClient()
    let future = milliseconds(now.addingTimeInterval(86_400 * 30))

    func engine(store: RecordingStore? = nil) -> EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store ?? self.store,
            weeklyProductID: "weekly",
            monthlyProductID: "monthly",
            yearlyProductID: "yearly",
            apnTopic: "com.example.app",
            deviceToken: "abcd",
            now: { now })
    }

    func order(subscribed: Bool, product: String? = "monthly") -> Order {
        Order(id: orderID, productName: product, isSubscribed: subscribed)
    }

    @Test func activeSubscriberIsNeverToldTheyCancelled() async throws {
        _ = try await engine().processReceipt(
            apns: client, order: order(subscribed: true), orderId: orderID.uuidString,
            latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
            pendingRenewalInfo: PendingRenewalInfo(autoRenewStatus: "1"))
        #expect(client.requests.isEmpty)
        #expect(store.updates.isEmpty)
    }

    @Test func refundRevokesThenPushesToTheConfiguredDevice() async throws {
        let status = try await engine().processReceipt(
            apns: client, order: order(subscribed: true), orderId: orderID.uuidString,
            latestReceiptInfo: LatestReceiptInfo(
                productId: "monthly", expiresDateMs: future,
                cancellationDateMs: milliseconds(now.addingTimeInterval(-60)), cancellationReason: "0"),
            pendingRenewalInfo: PendingRenewalInfo())

        #expect(status == .ok)
        #expect(store.updates.count == 1)
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(store.updates.first?.order.updatedAt == now)
        #expect(store.updates.first?.id == orderID)

        let request = try #require(client.requests.first)
        #expect(request.deviceToken == "abcd")
        #expect(request.topic == "com.example.app")
        #expect(request.pushType == "alert")
        #expect(request.collapseID == "cancelled")
    }

    /// Regression: the push used a fixed 1970 expiry, so APNs treated it as already stale.
    @Test func pushExpiryIsInTheFuture() async throws {
        _ = try await engine().processReceipt(
            apns: client, order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
            latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
            pendingRenewalInfo: PendingRenewalInfo())
        #expect(client.requests.first?.expiration == Int(now.timeIntervalSince1970) + 86_400)
    }

    @Test func pushDoesNotResetTheBadgeOrSendAnEmptyLaunchImage() async throws {
        _ = try await engine().processReceipt(
            apns: client, order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
            latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
            pendingRenewalInfo: PendingRenewalInfo())
        let json = try #require(client.requests.first?.json)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        #expect(aps["badge"] == nil)
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["launch-image"] == nil)
    }

    @Test func engineWithoutAPNsConfigurationThrowsBeforeSavingAnything() async {
        let googleOnly = EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
        await #expect(throws: EntitlementError.missingAPNsConfiguration) {
            _ = try await googleOnly.processReceipt(
                apns: client, order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
                latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
                pendingRenewalInfo: PendingRenewalInfo())
        }
        #expect(store.updates.isEmpty)
    }

    @Test func invalidOrderIDThrows() async {
        await #expect(throws: EntitlementError.invalidOrderID) {
            _ = try await engine().processReceipt(
                apns: client, order: order(subscribed: true), orderId: "not-a-uuid",
                latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
                pendingRenewalInfo: PendingRenewalInfo())
        }
    }

    /// Regression: errors used to be logged and swallowed, returning `.ok`.
    @Test func storeFailurePropagatesAndNoPushIsSent() async {
        let failing = RecordingStore(failure: TestFailure.boom)
        await #expect(throws: TestFailure.boom) {
            _ = try await engine(store: failing).processReceipt(
                apns: client, order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
                latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
                pendingRenewalInfo: PendingRenewalInfo())
        }
        #expect(client.requests.isEmpty)
    }

    @Test func pushFailurePropagatesAfterEntitlementIsSaved() async {
        let failingClient = FakeAPNSClient(failure: TestFailure.boom)
        await #expect(throws: TestFailure.boom) {
            _ = try await engine().processReceipt(
                apns: failingClient, order: order(subscribed: false, product: nil), orderId: orderID.uuidString,
                latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
                pendingRenewalInfo: PendingRenewalInfo())
        }
        #expect(store.updates.count == 1)
    }

    /// Regression: per-call state lived on the actor and was clobbered across suspension points.
    @Test func concurrentCallsKeepTheirOwnOrders() async throws {
        let engine = engine()
        let ids = (0..<50).map { _ in UUID() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [client, future] in
                    _ = try await engine.processReceipt(
                        apns: client,
                        order: Order(id: id, isSubscribed: false),
                        orderId: id.uuidString,
                        latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
                        pendingRenewalInfo: PendingRenewalInfo())
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
            yearlyProductID: "yearly", apnTopic: "t", deviceToken: "d", now: { clock.value })
        clock.value = now.addingTimeInterval(86_400 * 31)
        _ = try await engine.processReceipt(
            apns: client, order: order(subscribed: true), orderId: orderID.uuidString,
            latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: future),
            pendingRenewalInfo: PendingRenewalInfo())
        #expect(store.updates.first?.order.isSubscribed == false)
    }
}

/// Compile-time check that the real APNs client still satisfies the engine's API.
private func acceptsRealClient(
    engine: EntitlementEngine,
    client: APNSClient<JSONDecoder, JSONEncoder>,
    order: Order
) async throws {
    _ = try await engine.processReceipt(
        apns: client, order: order, orderId: "", latestReceiptInfo: .init(), pendingRenewalInfo: .init())
}
