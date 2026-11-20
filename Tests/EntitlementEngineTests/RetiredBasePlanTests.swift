import Foundation
import Testing
@testable import IAPEntitlementEngine

/// a catalog of base plan IDs under one Play product, "premium". The monthly slot used to
/// hold base plan "monthly" and now holds "monthly-v2".
@Suite("Retired base plan")
struct RetiredBasePlanTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()

    /// 2026-12-01, the same instant the other Google tests use.
    static let clock = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!

    var basePlanEngine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly-v2",
            yearlyProductID: "yearly", now: { Self.clock })
    }

    /// Each plan is its own Play product.
    var productEngine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { Self.clock })
    }

    func item(_ product: String, _ basePlan: String?, expiry: String? = "2027-01-15T08:00:00Z") -> String {
        let plan = basePlan.map { #","offerDetails":{"basePlanId":"\#($0)"}"# } ?? ""
        let expires = expiry.map { #","expiryTime":"\#($0)""# } ?? ""
        return #"{"productId":"\#(product)","autoRenewingPlan":{"autoRenewEnabled":true}\#(expires)\#(plan)}"#
    }

    func process(
        _ engine: EntitlementEngine, _ order: Order, state: String, items: [String], isRevoked: Bool = false
    ) async throws {
        let json = #"{"subscriptionState":"\#(state)","lineItems":[\#(items.joined(separator: ","))]}"#
        let purchase = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
        _ = try await engine.processGooglePlayPurchase(
            notifier: notifier, order: order, purchase: purchase, isRevoked: isRevoked)
    }

    let holder = Order(id: orderID, productName: "monthly", isSubscribed: true)

    // MARK: What the fix has to do

    @Test func expiryOfARetiredBasePlanEndsAccess() async throws {
        try await process(basePlanEngine, holder, state: "SUBSCRIPTION_STATE_EXPIRED", items: [item("premium", "monthly")])
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.isEmpty)
    }

    @Test func revocationOfARetiredBasePlanEndsAccess() async throws {
        try await process(
            basePlanEngine, holder, state: "SUBSCRIPTION_STATE_EXPIRED", items: [item("premium", "monthly")],
            isRevoked: true)
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.map(\.collapseID) == ["cancelled"])
    }

    @Test func accountHoldOfARetiredBasePlanEndsAccess() async throws {
        try await process(basePlanEngine, holder, state: "SUBSCRIPTION_STATE_ON_HOLD", items: [item("premium", "monthly")])
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.map(\.collapseID) == ["billing-issue"])
    }

    // MARK: With R1

    /// Without R1 this is the renewal that R4 newly turns from "unchanged" into a cut-off.
    @Test func renewalOfARetiredBasePlanLeavesItsSubscriberAlone() async throws {
        try await process(basePlanEngine, holder, state: "SUBSCRIPTION_STATE_ACTIVE", items: [item("premium", "monthly")])
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    @Test func gracePeriodOfARetiredBasePlanKeepsAccess() async throws {
        try await process(
            basePlanEngine, holder, state: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD", items: [item("premium", "monthly")])
        #expect(!store.updates.contains { $0.order.isSubscribed == false })
        #expect(notifier.sent.map(\.collapseID) == ["billing-issue"])
    }

    // MARK: Never grants

    /// The server wrote the plan name the client asked for. The purchase is real, but it is a
    /// cheaper subscription that is not one of the three.
    @Test func callerNamedBasePlanNeverStartsASubscription() async throws {
        try await process(
            basePlanEngine, Order(id: orderID, productName: "tier1", isSubscribed: false),
            state: "SUBSCRIPTION_STATE_ACTIVE", items: [item("supporter", "tier1")])
        #expect(!store.updates.contains { $0.order.isSubscribed == true })
        #expect(notifier.sent.isEmpty)
    }

    @Test func lapsedHolderOfARetiredBasePlanIsNotEntitledAgain() async throws {
        try await process(
            basePlanEngine, Order(id: orderID, productName: "monthly", isSubscribed: false),
            state: "SUBSCRIPTION_STATE_ACTIVE", items: [item("premium", "monthly")])
        #expect(!store.updates.contains { $0.order.isSubscribed == true })
        #expect(notifier.sent.isEmpty)
    }

    // MARK: The "other products are ignored" rule still holds

    /// `Order.init` defaults productName to "". An empty base plan must not match it.
    @Test(arguments: ["SUBSCRIPTION_STATE_EXPIRED", "SUBSCRIPTION_STATE_ON_HOLD", "SUBSCRIPTION_STATE_ACTIVE"])
    func emptyBasePlanDoesNotMatchAnEmptyProductName(state: String) async throws {
        try await process(
            basePlanEngine, Order(id: orderID, productName: "", isSubscribed: true),
            state: state, items: [item("another-product", "")])
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    @Test func missingBasePlanAndMissingProductNameChangeNothing() async throws {
        try await process(
            basePlanEngine, Order(id: orderID, productName: nil, isSubscribed: true),
            state: "SUBSCRIPTION_STATE_EXPIRED", items: [item("another-product", nil)])
        #expect(store.updates.isEmpty)
    }

    @Test func unrelatedBasePlanStillLeavesAHolderAlone() async throws {
        try await process(
            basePlanEngine, holder, state: "SUBSCRIPTION_STATE_EXPIRED", items: [item("another-product", "p1m")])
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    // MARK: Precedence and line item choice

    /// A catalog product ID has to win over a base plan that only the order remembers, or a
    /// customer who paid for a catalog product is not entitled.
    @Test func catalogProductWinsOverAHeldBasePlan() async throws {
        try await process(
            productEngine, Order(id: orderID, productName: "legacy", isSubscribed: false),
            state: "SUBSCRIPTION_STATE_ACTIVE", items: [item("yearly", "legacy")])
        #expect(store.updates.first?.order.isSubscribed == true)
        #expect(store.updates.first?.order.productName == "yearly")
    }

    /// The held plan has to be the item that is read, whatever else is on the purchase.
    @Test func heldBasePlanIsChosenOverAnUnrelatedLineItem() async throws {
        try await process(
            basePlanEngine, holder, state: "SUBSCRIPTION_STATE_EXPIRED",
            items: [item("addon", "extra", expiry: "2030-01-01T00:00:00Z"), item("premium", "monthly")])
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    /// The same gap for a retired product ID, which no base plan is involved in.
    @Test func heldRetiredProductIsChosenOverAnUnrelatedLineItem() async throws {
        try await process(
            productEngine, Order(id: orderID, productName: "monthly-old", isSubscribed: true),
            state: "SUBSCRIPTION_STATE_EXPIRED",
            items: [item("addon", "extra", expiry: "2030-01-01T00:00:00Z"), item("monthly-old", "p1m")])
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    // MARK: A limit that stays, to be documented

    /// Base plan IDs are only unique inside one Play product. Another product's plan with the
    /// held name is read as the held plan, the same way a catalog plan name already is.
    @Test func anotherProductSharingTheHeldBasePlanNameEndsAccess() async throws {
        try await process(
            basePlanEngine, holder, state: "SUBSCRIPTION_STATE_EXPIRED", items: [item("cloud_storage", "monthly")])
        #expect(store.updates.first?.order.isSubscribed == false)
    }
}
