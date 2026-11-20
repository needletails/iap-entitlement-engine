import Foundation
import Testing
@testable import IAPEntitlementEngine

/// a product the order holds that is no longer in the catalog.
/// "monthly" used to fill the monthly slot. The slot now names "monthly.2026".
@Suite("Retired product")
struct RetiredProductTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()

    var engine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly.2026",
            yearlyProductID: "yearly", now: { now })
    }

    func apple(
        _ order: Order, _ transaction: AppStoreTransaction,
        _ renewal: AppStoreRenewalInfo = AppStoreRenewalInfo(autoRenewStatus: 1)
    ) async throws {
        _ = try await engine.processAppStoreTransaction(
            notifier: notifier, order: order,
            transaction: transaction, renewalInfo: renewal)
    }

    func google(_ order: Order, _ json: String, isRevoked: Bool = false) async throws {
        let purchase = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
        _ = try await engine.processGooglePlayPurchase(
            notifier: notifier, order: order, purchase: purchase, isRevoked: isRevoked)
    }

    let future = now.addingTimeInterval(30 * 86_400)

    // MARK: What the fix has to do

    @Test func renewalOfARetiredProductKeepsItsSubscriberQuietly() async throws {
        try await apple(
            Order(id: orderID, productName: "monthly", isSubscribed: true),
            AppStoreTransaction(productId: "monthly", expiresDate: future))
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    @Test func gracePeriodOnARetiredProductKeepsAccessAndAsksForPayment() async throws {
        try await apple(
            Order(id: orderID, productName: "monthly", isSubscribed: true),
            AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(-60)),
            AppStoreRenewalInfo(autoRenewStatus: 1, gracePeriodExpiresDate: now.addingTimeInterval(86_400)))
        #expect(!store.updates.contains { $0.order.isSubscribed == false })
        #expect(notifier.sent.map(\.collapseID) == ["billing-issue"])
    }

    @Test func expiryWarningStillReachesARetiredProduct() async throws {
        try await apple(
            Order(id: orderID, productName: "monthly", isSubscribed: true),
            AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(3_600)),
            AppStoreRenewalInfo(autoRenewStatus: 0))
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.map(\.collapseID) == ["expiring-today"])
    }

    // MARK: Real ends still end

    @Test func expiryOfARetiredProductEndsAccess() async throws {
        try await apple(
            Order(id: orderID, productName: "monthly", isSubscribed: true),
            AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(-60)),
            AppStoreRenewalInfo(autoRenewStatus: 0))
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.isEmpty)
    }

    @Test func refundOfARetiredProductEndsAccess() async throws {
        try await apple(
            Order(id: orderID, productName: "monthly", isSubscribed: true),
            AppStoreTransaction(
                productId: "monthly", expiresDate: future, revocationDate: now.addingTimeInterval(-60),
                revocationReason: 0))
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.map(\.collapseID) == ["cancelled"])
    }

    @Test func billingRetryOfARetiredProductEndsAccess() async throws {
        try await apple(
            Order(id: orderID, productName: "monthly", isSubscribed: true),
            AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(-60)),
            AppStoreRenewalInfo(autoRenewStatus: 1, isInBillingRetryPeriod: true))
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.map(\.collapseID) == ["billing-issue"])
    }

    @Test func googleExpiryAndHoldOfARetiredProductIDEndAccess() async throws {
        try await google(
            Order(id: orderID, productName: "monthly", isSubscribed: true),
            #"{"subscriptionState":"SUBSCRIPTION_STATE_EXPIRED","lineItems":[{"productId":"monthly","expiryTime":"2027-01-01T00:00:00Z"}]}"#)
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    // MARK: Never grants

    /// The caller, not the engine, wrote this product name. It names a real subscription the
    /// customer bought, but not one of the three.
    @Test func callerNamedProductOutsideTheCatalogNeverStartsASubscription() async throws {
        try await apple(
            Order(id: orderID, productName: "cloud.storage", isSubscribed: false),
            AppStoreTransaction(productId: "cloud.storage", expiresDate: future))
        #expect(!store.updates.contains { $0.order.isSubscribed == true })
        #expect(notifier.sent.isEmpty)
    }

    @Test func nilSubscribedFlagIsNotASubscriber() async throws {
        var order = Order(id: orderID, productName: "cloud.storage")
        order.isSubscribed = nil
        try await apple(order, AppStoreTransaction(productId: "cloud.storage", expiresDate: future))
        #expect(!store.updates.contains { $0.order.isSubscribed == true })
        #expect(notifier.sent.isEmpty)
    }

    @Test func unrelatedProductOnAnOrderWithNoProductChangesNothing() async throws {
        try await apple(
            Order(id: orderID, productName: nil, isSubscribed: false),
            AppStoreTransaction(productId: "from-another-app", expiresDate: future))
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    /// `Order.init` defaults productName to "". A store item that names no product must not
    /// count as "the product the order holds".
    @Test func emptyProductNameNeverMatchesAnEmptyStoreProduct() async throws {
        try await google(
            Order(id: orderID),
            #"{"subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","lineItems":[{"productId":"","expiryTime":"2099-01-01T00:00:00Z","autoRenewingPlan":{"autoRenewEnabled":true}}]}"#)
        #expect(!store.updates.contains { $0.order.isSubscribed == true })
        #expect(notifier.sent.isEmpty)
    }

    /// A long-standing subscriber whose order was written before productName was stored.
    @Test func emptyProductNameOnASubscribedOrderIsNotAHeldProduct() {
        let evaluator = EntitlementEvaluator(catalog: catalog)
        let decision = evaluator.evaluate(
            SubscriptionSnapshot(
                productID: "", lifecycle: .active, expiresAt: future, autoRenewEnabled: true, offer: .none),
            order: Order(id: orderID, productName: "", isSubscribed: true), now: now)
        #expect(decision.isSubscribed != true)
    }

    /// The price of only ever keeping, never starting: after a lapse the order no longer proves
    /// the engine granted this product, so a comeback is not entitled. This must be documented.
    @Test func lapsedSubscriberOfARetiredProductIsNotEntitledAgain() async throws {
        try await apple(
            Order(id: orderID, productName: "monthly", isSubscribed: false),
            AppStoreTransaction(productId: "monthly", expiresDate: future))
        #expect(!store.updates.contains { $0.order.isSubscribed == true })
        #expect(notifier.sent.isEmpty)
    }

    /// A retired product never earns a "monthly active" message through the default slot.
    @Test func retiredProductNeverUsesTheMonthlyFallbackMessage() {
        let evaluator = EntitlementEvaluator(catalog: catalog)
        for subscribed in [true, false] {
            for lifecycle in [SubscriptionSnapshot.Lifecycle.active, .gracePeriod] {
                let decision = evaluator.evaluate(
                    SubscriptionSnapshot(
                        productID: "retired", lifecycle: lifecycle, expiresAt: future, autoRenewEnabled: true,
                        offer: .none),
                    order: Order(id: orderID, productName: "retired", isSubscribed: subscribed), now: now)
                #expect(decision.notification != .monthlyActive)
            }
        }
    }
}
