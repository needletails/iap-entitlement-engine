import Foundation
import Testing
@testable import IAPEntitlementEngine

/// Play reports ACTIVE with auto-renew on while it is still collecting a renewal payment,
/// and expiryTime is already behind.
@Suite("Renewal in progress")
struct RenewalInProgressTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()

    /// 2027-01-15T08:00:00Z
    static let clock = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
    static let anHourAgo = "2027-01-15T07:00:00Z"

    func engine(now: Date = clock) -> EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
    }

    func process(
        _ order: Order, _ json: String, isRevoked: Bool = false, now: Date = clock
    ) async throws {
        let purchase = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
        _ = try await engine(now: now).processGooglePlayPurchase(
            notifier: notifier, order: order, purchase: purchase, isRevoked: isRevoked)
    }

    func purchase(state: String, expiry: String = anHourAgo, plan: String = #","autoRenewingPlan":{"autoRenewEnabled":true}"#,
                  extra: String = "") -> String {
        #"{"subscriptionState":"\#(state)"\#(extra),"lineItems":[{"productId":"monthly","expiryTime":"\#(expiry)"\#(plan)}]}"#
    }

    let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)

    // MARK: What the fix has to do

    @Test func renewalInProgressLeavesTheSubscriberAlone() async throws {
        try await process(subscriber, purchase(state: "SUBSCRIPTION_STATE_ACTIVE"))
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    @Test func expiryExactlyNowIsStillInProgress() async throws {
        try await process(subscriber, purchase(state: "SUBSCRIPTION_STATE_ACTIVE", expiry: "2027-01-15T08:00:00Z"))
        #expect(store.updates.isEmpty)
    }

    /// The old plan has run out and the new one is waiting to start, so the subscription goes on.
    @Test func deferredPlanChangeOverIsStillInProgress() async throws {
        let json = #"""
        {"subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","lineItems":[
          {"productId":"yearly","expiryTime":"2027-01-15T07:00:00Z","autoRenewingPlan":{"autoRenewEnabled":false},
           "deferredItemReplacement":{"productId":"monthly"}},
          {"productId":"monthly","autoRenewingPlan":{"autoRenewEnabled":true}}]}
        """#
        try await process(Order(id: orderID, productName: "yearly", isSubscribed: true), json)
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    // MARK: Never grants

    @Test func renewalInProgressNeverStartsASubscription() async throws {
        try await process(
            Order(id: orderID, productName: "monthly", isSubscribed: false), purchase(state: "SUBSCRIPTION_STATE_ACTIVE"))
        #expect(!store.updates.contains { $0.order.isSubscribed == true })
        #expect(notifier.sent.isEmpty)
    }

    // MARK: Real ends still end

    @Test(arguments: [
        ("SUBSCRIPTION_STATE_EXPIRED", [String]()),
        ("SUBSCRIPTION_STATE_ON_HOLD", ["billing-issue"]),
        ("SUBSCRIPTION_STATE_PAUSED", []),
    ])
    func everyStateThatEndsAccessStillDoes(state: String, pushes: [String]) async throws {
        try await process(subscriber, purchase(state: state))
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.map(\.collapseID) == pushes)
    }

    /// Google reports a subscription cancelled after account hold as CANCELED with a past expiryTime.
    @Test func canceledPastItsExpiryEndsAccess() async throws {
        try await process(
            subscriber, purchase(state: "SUBSCRIPTION_STATE_CANCELED", plan: #","autoRenewingPlan":{"autoRenewEnabled":false}"#))
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    /// A stale or wrong auto-renew flag on a cancelled purchase must not hold access open.
    @Test func canceledPastItsExpiryEndsAccessWhateverTheRenewFlagSays() async throws {
        try await process(subscriber, purchase(state: "SUBSCRIPTION_STATE_CANCELED"))
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    /// A cancelled subscription with a plan change still waiting is reported as auto-renewing.
    @Test func canceledWithADeferredPlanStillEndsAccess() async throws {
        let json = #"""
        {"subscriptionState":"SUBSCRIPTION_STATE_CANCELED","lineItems":[
          {"productId":"yearly","expiryTime":"2027-01-15T07:00:00Z","autoRenewingPlan":{"autoRenewEnabled":false}},
          {"productId":"monthly","autoRenewingPlan":{"autoRenewEnabled":true}}]}
        """#
        try await process(Order(id: orderID, productName: "yearly", isSubscribed: true), json)
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    @Test func prepaidPlanPastItsExpiryEndsAccess() async throws {
        try await process(subscriber, purchase(state: "SUBSCRIPTION_STATE_ACTIVE", plan: ""))
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    @Test func autoRenewOffPastItsExpiryEndsAccess() async throws {
        try await process(
            subscriber, purchase(state: "SUBSCRIPTION_STATE_ACTIVE", plan: #","autoRenewingPlan":{"autoRenewEnabled":false}"#))
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    @Test func revocationWinsOverARenewalInProgress() async throws {
        try await process(subscriber, purchase(state: "SUBSCRIPTION_STATE_ACTIVE"), isRevoked: true)
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.map(\.collapseID) == ["cancelled"])
    }

    @Test func gracePeriodPastItsExpiryStillEndsAccess() async throws {
        try await process(subscriber, purchase(state: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"))
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    // MARK: A limit that stays, to be documented

    /// The rule trusts that the purchase was fetched just now. A stored copy processed again a
    /// year later is still "in progress", so it never ends by the clock.
    @Test func aStoredCopyOfAnActivePurchaseNeverEndsByTheClock() async throws {
        try await process(
            subscriber, purchase(state: "SUBSCRIPTION_STATE_ACTIVE"), now: Self.clock.addingTimeInterval(365 * 86_400))
        #expect(store.updates.isEmpty)
    }
}
