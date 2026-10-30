import Foundation
import Synchronization
import Testing
@testable import IAPEntitlementEngine

private func purchase(
    state: String,
    expiry: String? = "2027-01-15T08:00:00.000Z",
    autoRenew: Bool? = true,
    offerPhase: String = "",
    product: String = "premium",
    basePlan: String = "monthly",
    extra: String = ""
) throws -> GooglePlaySubscriptionPurchase {
    let expiryField = expiry.map { #""expiryTime":"\#($0)","# } ?? ""
    let plan = autoRenew.map { #""autoRenewingPlan":{"autoRenewEnabled":\#($0)},"# } ?? ""
    let json = #"""
    {"kind":"androidpublisher#subscriptionPurchaseV2","subscriptionState":"\#(state)","startTime":"2026-01-01T00:00:00Z",
     "acknowledgementState":"ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",\#(extra)
     "lineItems":[{\#(expiryField)\#(plan)\#(offerPhase)"productId":"\#(product)",
       "offerDetails":{"basePlanId":"\#(basePlan)"}}]}
    """#
    return try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
}

private let googleNow = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!
private let googleExpiry = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!

@Suite("Google Play mapping")
struct GooglePlayAdapterTests {
    func map(_ purchase: GooglePlaySubscriptionPurchase, isRevoked: Bool = false) throws -> SubscriptionSnapshot {
        try GooglePlayAdapter.snapshot(purchase: purchase, catalog: catalog, isRevoked: isRevoked)
    }

    @Test func activeMapsWithFractionalSecondExpiry() throws {
        let snapshot = try map(purchase(state: "SUBSCRIPTION_STATE_ACTIVE"))
        #expect(snapshot.lifecycle == .active)
        #expect(snapshot.productID == "monthly")
        #expect(snapshot.expiresAt == googleExpiry)
        #expect(snapshot.autoRenewEnabled)
    }

    @Test func expiryWithoutFractionalSecondsParses() throws {
        let snapshot = try map(purchase(state: "SUBSCRIPTION_STATE_ACTIVE", expiry: "2027-01-15T08:00:00Z"))
        #expect(snapshot.expiresAt == googleExpiry)
    }

    @Test func expiryWithNanosecondsParses() throws {
        let snapshot = try map(purchase(state: "SUBSCRIPTION_STATE_ACTIVE", expiry: "2027-01-15T08:00:00.123456789Z"))
        #expect(snapshot.expiresAt != nil)
    }

    @Test func productIDMatchesWhenEachPlanIsItsOwnProduct() throws {
        let snapshot = try map(purchase(state: "SUBSCRIPTION_STATE_ACTIVE", product: "yearly", basePlan: "p1y"))
        #expect(snapshot.productID == "yearly")
    }

    @Test func unmatchedProductKeepsItsProductIDSoItIsRejected() throws {
        let snapshot = try map(purchase(state: "SUBSCRIPTION_STATE_ACTIVE", product: "other", basePlan: "other-plan"))
        #expect(snapshot.productID == "other")
    }

    /// Google documents CANCELED as "keep access until expiryTime".
    @Test func canceledKeepsAccessUntilExpiryWithAutoRenewOff() throws {
        let snapshot = try map(purchase(state: "SUBSCRIPTION_STATE_CANCELED", autoRenew: false))
        #expect(snapshot.lifecycle == .active)
        #expect(!snapshot.autoRenewEnabled)
    }

    @Test func gracePeriodMaps() throws {
        #expect(try map(purchase(state: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD")).lifecycle == .gracePeriod)
    }

    @Test func accountHoldBlocksForBilling() throws {
        #expect(try map(purchase(state: "SUBSCRIPTION_STATE_ON_HOLD")).lifecycle == .suspended(.billing))
    }

    @Test func pauseBlocks() throws {
        #expect(try map(purchase(state: "SUBSCRIPTION_STATE_PAUSED")).lifecycle == .suspended(.paused))
    }

    /// Revocations are EXPIRED with no guarantee that expiryTime is in the past.
    @Test func expiredIgnoresAFutureExpiryTime() throws {
        #expect(try map(purchase(state: "SUBSCRIPTION_STATE_EXPIRED")).lifecycle == .expired)
    }

    @Test func revokedRTDNWinsOverExpiredState() throws {
        let snapshot = try map(purchase(state: "SUBSCRIPTION_STATE_EXPIRED"), isRevoked: true)
        #expect(snapshot.lifecycle == .revoked(.other))
    }

    @Test func pendingLeavesTheOrderAlone() throws {
        #expect(try map(purchase(state: "SUBSCRIPTION_STATE_PENDING")).lifecycle == .pending)
    }

    /// A cancelled upgrade must not take away the subscription the user already has.
    @Test func pendingPurchaseCanceledLeavesTheOrderAlone() throws {
        #expect(try map(purchase(state: "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED")).lifecycle == .pending)
    }

    /// The replacement token owns the entitlement, so the old token must not revoke it.
    @Test func replacedSubscriptionLeavesTheOrderAlone() throws {
        let replaced = try purchase(
            state: "SUBSCRIPTION_STATE_EXPIRED",
            extra: #""canceledStateContext":{"replacementCancellation":{}},"#)
        #expect(try map(replaced).lifecycle == .pending)
    }

    @Test func userCancellationIsNotAReplacement() throws {
        let canceled = try purchase(
            state: "SUBSCRIPTION_STATE_CANCELED",
            extra: #""canceledStateContext":{"userInitiatedCancellation":{"cancelTime":"2026-11-01T00:00:00Z"}},"#)
        #expect(try map(canceled).lifecycle == .active)
    }

    @Test func freeTrialPhaseMaps() throws {
        let trial = try purchase(state: "SUBSCRIPTION_STATE_ACTIVE", offerPhase: #""offerPhase":{"freeTrial":{}},"#)
        #expect(try map(trial).offer == .trial)
    }

    @Test func introPhaseMaps() throws {
        let intro = try purchase(state: "SUBSCRIPTION_STATE_ACTIVE", offerPhase: #""offerPhase":{"introductoryPrice":{}},"#)
        #expect(try map(intro).offer == .introductory)
    }

    @Test func basePricePhaseIsNoOffer() throws {
        let base = try purchase(state: "SUBSCRIPTION_STATE_ACTIVE", offerPhase: #""offerPhase":{"basePrice":{}},"#)
        #expect(try map(base).offer == .none)
    }

    @Test func prepaidPlanDoesNotAutoRenew() throws {
        let prepaid = try purchase(state: "SUBSCRIPTION_STATE_ACTIVE", autoRenew: nil)
        #expect(try map(prepaid).autoRenewEnabled == false)
    }

    @Test func unknownStateThrowsSoAccessIsNotChanged() {
        #expect(throws: EntitlementError.unsupportedState("SUBSCRIPTION_STATE_NEW_THING")) {
            try map(purchase(state: "SUBSCRIPTION_STATE_NEW_THING"))
        }
    }

    @Test func unspecifiedStateThrows() {
        #expect(throws: EntitlementError.unsupportedState("SUBSCRIPTION_STATE_UNSPECIFIED")) {
            try map(purchase(state: "SUBSCRIPTION_STATE_UNSPECIFIED"))
        }
    }

    @Test func malformedExpiryThrows() {
        #expect(throws: EntitlementError.invalidDate(field: "expiryTime")) {
            try map(purchase(state: "SUBSCRIPTION_STATE_ACTIVE", expiry: "soon"))
        }
    }

    @Test func missingExpiryOnActiveThrows() {
        #expect(throws: EntitlementError.invalidDate(field: "expiryTime")) {
            try map(purchase(state: "SUBSCRIPTION_STATE_ACTIVE", expiry: nil))
        }
    }

    @Test func noLineItemsOnActiveThrows() throws {
        let json = #"{"subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","lineItems":[]}"#
        let empty = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
        #expect(throws: EntitlementError.invalidDate(field: "expiryTime")) {
            try map(empty)
        }
    }

    @Test func picksTheLatestExpiringCatalogLineItem() throws {
        let json = #"""
        {"subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","lineItems":[
          {"productId":"addon","expiryTime":"2030-01-01T00:00:00Z"},
          {"productId":"weekly","expiryTime":"2026-12-05T00:00:00Z"},
          {"productId":"monthly","expiryTime":"2027-01-15T08:00:00Z"}]}
        """#
        let multi = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
        let snapshot = try map(multi)
        #expect(snapshot.productID == "monthly")
        #expect(snapshot.expiresAt == googleExpiry)
    }

    @Test func exposesAcknowledgementAndTestFlags() throws {
        let test = try purchase(state: "SUBSCRIPTION_STATE_ACTIVE", extra: #""testPurchase":{},"#)
        #expect(test.isTestPurchase)
        #expect(!test.needsAcknowledgement)
    }

    @Test func flagsUnacknowledgedPurchases() throws {
        let json = #"{"subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","acknowledgementState":"ACKNOWLEDGEMENT_STATE_PENDING"}"#
        let pending = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
        #expect(pending.needsAcknowledgement)
        #expect(!pending.isTestPurchase)
    }
}

@Suite("Google Play engine flow")
struct GooglePlayEngineTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()

    var engine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { googleNow })
    }

    @Test func newPurchaseGrantsAndNotifies() async throws {
        _ = try await engine.processGooglePlayPurchase(
            notifier: notifier, order: Order(id: orderID, isSubscribed: false), orderId: orderID.uuidString,
            purchase: purchase(state: "SUBSCRIPTION_STATE_ACTIVE"))
        #expect(store.updates.first?.order.isSubscribed == true)
        #expect(store.updates.first?.order.productName == "monthly")
        #expect(notifier.sent.first?.collapseID == "monthly-active")
        #expect(notifier.sent.first?.expiresAt == googleNow.addingTimeInterval(86_400))
    }

    @Test func accountHoldRevokesAccess() async throws {
        _ = try await engine.processGooglePlayPurchase(
            notifier: notifier, order: Order(id: orderID, productName: "monthly", isSubscribed: true),
            orderId: orderID.uuidString, purchase: purchase(state: "SUBSCRIPTION_STATE_ON_HOLD"))
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.first?.collapseID == "billing-issue")
    }

    @Test func pendingCancellationDoesNotTouchTheStore() async throws {
        _ = try await engine.processGooglePlayPurchase(
            notifier: notifier, order: Order(id: orderID, productName: "monthly", isSubscribed: true),
            orderId: orderID.uuidString, purchase: purchase(state: "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED"))
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }
}

final class RecordingTransport: FCMTransport {
    struct Call: Sendable {
        let url: String
        let headers: [String: String]
        let body: Data
    }

    private let calls_ = Mutex<[Call]>([])
    let response: FCMTransportResponse

    init(status: Int = 200, body: String = #"{"name":"projects/p/messages/1"}"#) {
        response = FCMTransportResponse(status: status, body: Data(body.utf8))
    }

    var calls: [Call] { calls_.withLock { $0 } }

    func post(url: String, headers: [String: String], body: Data) async throws -> FCMTransportResponse {
        calls_.withLock { $0.append(Call(url: url, headers: headers, body: body)) }
        return response
    }
}

struct StaticToken: FCMAccessTokenProvider {
    func accessToken() async throws -> String { "secret-token" }
}

@Suite("FCM notifier")
struct FCMNotifierTests {
    func notifier(_ transport: RecordingTransport) -> FCMEntitlementNotifier {
        FCMEntitlementNotifier(
            projectID: "my-project", registrationToken: "device-1",
            accessTokenProvider: StaticToken(), transport: transport)
    }

    let expiry = Date(timeIntervalSince1970: 1_800_086_400)
    let sendTime = Date(timeIntervalSince1970: 1_800_000_000)

    func sentMessage(_ transport: RecordingTransport) throws -> [String: Any] {
        let call = try #require(transport.calls.first)
        let root = try #require(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        return try #require(root["message"] as? [String: Any])
    }

    @Test func postsToTheV1EndpointWithBearerAuth() async throws {
        let transport = RecordingTransport()
        try await notifier(transport).send(
            IAPPayload(title: "T", subtitle: "S", body: "B"), collapseID: "c", expiresAt: expiry)
        let call = try #require(transport.calls.first)
        #expect(call.url == "https://fcm.googleapis.com/v1/projects/my-project/messages:send")
        #expect(call.headers["Authorization"] == "Bearer secret-token")
        #expect(call.headers["Content-Type"] == "application/json")
    }

    @Test func foldsSubtitleIntoBodyBecauseFCMHasNoSubtitle() async throws {
        let transport = RecordingTransport()
        try await notifier(transport).send(
            IAPPayload(title: "T", subtitle: "S", body: "B"), collapseID: "c", expiresAt: expiry)
        let message = try sentMessage(transport)
        #expect(message["token"] as? String == "device-1")
        let notification = try #require(message["notification"] as? [String: String])
        #expect(notification == ["title": "T", "body": "S\nB"])
    }

    @Test func omitsEmptyPartsFromTheBody() async throws {
        let transport = RecordingTransport()
        try await notifier(transport).send(
            IAPPayload(title: "T", subtitle: "S", body: ""), collapseID: "c", expiresAt: expiry)
        let notification = try #require(sentMessage(transport)["notification"] as? [String: String])
        #expect(notification["body"] == "S")
    }

    @Test func setsAndroidDeliveryOptions() async throws {
        let transport = RecordingTransport()
        let notifier = FCMEntitlementNotifier(
            projectID: "my-project", registrationToken: "device-1",
            accessTokenProvider: StaticToken(), transport: transport, now: { sendTime })
        try await notifier.send(IAPPayload(title: "T", subtitle: "", body: ""), collapseID: "cancelled", expiresAt: expiry)
        let android = try #require(sentMessage(transport)["android"] as? [String: String])
        #expect(android == ["ttl": "86400s", "priority": "HIGH", "collapseKey": "cancelled"])
    }

    @Test func passesBinaryPayloadAsBase64Data() async throws {
        let transport = RecordingTransport()
        try await notifier(transport).send(
            IAPPayload(title: "T", subtitle: "", body: "", data: Data([1, 2])), collapseID: "c", expiresAt: expiry)
        let data = try #require(sentMessage(transport)["data"] as? [String: String])
        #expect(data == ["payload": "AQI="])
    }

    @Test func staleTokenIsReportedSoCallersCanForgetIt() async {
        let transport = RecordingTransport(status: 404, body: #"""
        {"error":{"code":404,"status":"NOT_FOUND","details":[
          {"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"UNREGISTERED"}]}}
        """#)
        await #expect(throws: FCMError.unregistered) {
            try await notifier(transport).send(
                IAPPayload(title: "T", subtitle: "", body: ""), collapseID: "c", expiresAt: expiry)
        }
    }

    @Test func otherFailuresCarryTheStatus() async {
        let transport = RecordingTransport(status: 503, body: "nope")
        await #expect(throws: FCMError.requestFailed(status: 503, body: "nope")) {
            try await notifier(transport).send(
                IAPPayload(title: "T", subtitle: "", body: ""), collapseID: "c", expiresAt: expiry)
        }
    }

    @Test func projectIDIsEscapedInTheURL() async throws {
        let transport = RecordingTransport()
        let notifier = FCMEntitlementNotifier(
            projectID: "a/b", registrationToken: "t", accessTokenProvider: StaticToken(), transport: transport)
        try await notifier.send(IAPPayload(title: "T", subtitle: "", body: ""), collapseID: "c", expiresAt: expiry)
        #expect(transport.calls.first?.url == "https://fcm.googleapis.com/v1/projects/a%2Fb/messages:send")
    }
}
