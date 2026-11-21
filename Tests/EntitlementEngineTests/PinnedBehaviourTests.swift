import APNSCore
import Foundation
import Testing
@testable import IAPEntitlementEngine

/// Behaviour that deliberate breakage showed no test was holding in place.
@Suite("Pinned behaviour")
struct PinnedBehaviourTests {
    @Test func verifyReceiptJSONKeysReachTheRules() throws {
        func receipt(_ extra: String) throws -> LatestReceiptInfo {
            let json = #"""
            {"quantity":"1","product_id":"monthly","transaction_id":"2","original_transaction_id":"1",
             "purchase_date":"x","purchase_date_ms":"1","purchase_date_pst":"x","original_purchase_date":"x",
             "original_purchase_date_ms":"1","original_purchase_date_pst":"x","expires_date":"x",
             "expires_date_pst":"x","web_order_line_item_id":"3","is_trial_period":"false",
             "is_in_intro_offer_period":"false","subscription_group_identifier":"4",\#(extra)}
            """#
            return try JSONDecoder().decode(LatestReceiptInfo.self, from: Data(json.utf8))
        }
        func renewal(_ extra: String) throws -> PendingRenewalInfo {
            let json = #"""
            {"auto_renew_product_id":"monthly","product_id":"monthly","original_transaction_id":"1",\#(extra)}
            """#
            return try JSONDecoder().decode(PendingRenewalInfo.self, from: Data(json.utf8))
        }
        func map(_ receipt: LatestReceiptInfo, _ renewal: PendingRenewalInfo) throws -> SubscriptionSnapshot {
            try AppleReceiptAdapter.snapshot(latestReceiptInfo: receipt, pendingRenewalInfo: renewal, now: now)
        }
        // `now` is 1800000000000 ms. One minute earlier, 30 days later and 3 days later:
        let lapsed = #""expires_date_ms":"1799999940000""#
        let running = #""expires_date_ms":"1802592000000""#

        let refund = try map(
            receipt(running + #","cancellation_date_ms":"1799999940000","cancellation_reason":"1""#),
            renewal(#""auto_renew_status":"0""#))
        #expect(refund.lifecycle == .revoked(.appIssue))
        #expect(!refund.autoRenewEnabled)

        let upgrade = try map(
            receipt(running + #","cancellation_date_ms":"1799999940000","is_upgraded":"true""#),
            renewal(#""auto_renew_status":"1""#))
        #expect(upgrade.lifecycle == .upgraded)

        let grace = try map(
            receipt(lapsed),
            renewal(#""auto_renew_status":"1","is_in_billing_retry_period":"1","grace_period_expires_date_ms":"1800259200000""#))
        #expect(grace.lifecycle == .gracePeriod)
        #expect(grace.expiresAt == now.addingTimeInterval(86_400 * 3))

        let retry = try map(receipt(lapsed), renewal(#""auto_renew_status":"1","is_in_billing_retry_period":"1""#))
        #expect(retry.lifecycle == .suspended(.billing))
    }

    @Test func appleDataWithAnOriginalIDIsAcceptedWhenRenewalInfoHasNone() async throws {
        let expiry = now.addingTimeInterval(86_400 * 30)

        let signed = try AppStoreSignedDataAdapter.snapshot(
            transaction: AppStoreTransaction(productId: "monthly", originalTransactionId: "1000000123", expiresDate: expiry),
            renewalInfo: AppStoreRenewalInfo(),
            now: now)
        #expect(signed.lifecycle == .active)

        let receipt = try AppleReceiptAdapter.snapshot(
            latestReceiptInfo: LatestReceiptInfo(
                productId: "monthly", originalTransactionId: "1000000123", expiresDateMs: milliseconds(expiry)),
            pendingRenewalInfo: PendingRenewalInfo(),
            now: now)
        #expect(receipt.lifecycle == .active)

        // The usual first purchase: a client sends its transaction, and the server has no renewal info yet.
        let store = RecordingStore()
        let engine = EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
        _ = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: Order(id: orderID, productName: nil, isSubscribed: false),
            transaction: AppStoreTransaction(productId: "monthly", originalTransactionId: "1000000123", expiresDate: expiry),
            renewalInfo: AppStoreRenewalInfo())
        #expect(store.updates.first?.order.isSubscribed == true)
    }

    @Test func customerReceivesTheCopyConfiguredForTheirEvent() async throws {
        var messages = EntitlementMessages()
        messages.upgraded = IAPPayload(title: "upgraded", subtitle: "s-upgraded", body: "b-upgraded")
        messages.billingIssue = IAPPayload(title: "billing-issue", subtitle: "s-billing-issue", body: "b-billing-issue")
        messages.expiringToday = IAPPayload(title: "expiring-today", subtitle: "s-expiring-today", body: "b-expiring-today")
        messages.trialStarted = IAPPayload(title: "trial-started", subtitle: "s-trial-started", body: "b-trial-started")
        messages.introOfferStarted = IAPPayload(
            title: "intro-offer-started", subtitle: "s-intro-offer-started", body: "b-intro-offer-started")
        messages.weeklyActive = IAPPayload(title: "weekly-active", subtitle: "s-weekly-active", body: "b-weekly-active")
        messages.monthlyActive = IAPPayload(title: "monthly-active", subtitle: "s-monthly-active", body: "b-monthly-active")
        messages.yearlyActive = IAPPayload(title: "yearly-active", subtitle: "s-yearly-active", body: "b-yearly-active")
        messages.cancelled = IAPPayload(title: "cancelled", subtitle: "s-cancelled", body: "b-cancelled")
        messages.cancelledAppIssue = IAPPayload(
            title: "cancelled-app-issue", subtitle: "s-cancelled-app-issue", body: "b-cancelled-app-issue")
        messages.notSubscribed = IAPPayload(title: "not-subscribed", subtitle: "s-not-subscribed", body: "b-not-subscribed")
        messages.purchased = IAPPayload(title: "purchased", subtitle: "s-purchased", body: "b-purchased")
        messages.purchaseRefunded = IAPPayload(
            title: "purchase-refunded", subtitle: "s-purchase-refunded", body: "b-purchase-refunded")
        messages.purchaseReinstated = IAPPayload(
            title: "purchase-reinstated", subtitle: "s-purchase-reinstated", body: "b-purchase-reinstated")

        // Every notification maps to its own copy.
        for notification in EntitlementNotification.allCases {
            #expect(messages.payload(for: notification).title == notification.rawValue)
        }

        // The engine sends the copy it was created with, for the product slot it was created with,
        // and the APNs alert carries all of it.
        let engine = EntitlementEngine(
            storeDelegate: RecordingStore(), weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", messages: messages, now: { now })
        let client = FakeAPNSClient()
        _ = try await engine.processAppStoreTransaction(
            notifier: APNSEntitlementNotifier(client: client, topic: "com.example.app", deviceToken: "abcd"),
            order: Order(id: orderID, productName: nil, isSubscribed: false),
            transaction: AppStoreTransaction(productId: "yearly", expiresDate: now.addingTimeInterval(86_400 * 365)),
            renewalInfo: AppStoreRenewalInfo(autoRenewStatus: 1))

        let request = try #require(client.requests.first)
        #expect(request.collapseID == "yearly-active")
        let object = try #require(JSONSerialization.jsonObject(with: request.json) as? [String: Any])
        let aps = try #require(object["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "yearly-active")
        #expect(alert["subtitle"] as? String == "s-yearly-active")
        #expect(alert["body"] as? String == "b-yearly-active")
        #expect(aps["sound"] as? String == "default")
    }

    @Test func readmeBehaviourRowsHoldAtTheirEdges() {
        let evaluator = EntitlementEvaluator(catalog: catalog)
        func snapshot(
            _ lifecycle: SubscriptionSnapshot.Lifecycle, product: String = "monthly",
            expiresIn: TimeInterval = 86_400 * 30, autoRenew: Bool = true
        ) -> SubscriptionSnapshot {
            SubscriptionSnapshot(
                productID: product, lifecycle: lifecycle, expiresAt: now.addingTimeInterval(expiresIn),
                autoRenewEnabled: autoRenew, offer: .none)
        }
        let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)
        let lapsed = Order(id: orderID, productName: "monthly", isSubscribed: false)

        // "Expired | No | None", for the subscriber's own product.
        #expect(evaluator.evaluate(snapshot(.expired, expiresIn: -60), order: subscriber, now: now)
            == EntitlementDecision(isSubscribed: false, productName: nil, notification: nil))

        // "Grace period | Yes | Payment issue", whatever the order said before.
        #expect(evaluator.evaluate(snapshot(.gracePeriod, expiresIn: 86_400), order: lapsed, now: now)
            == EntitlementDecision(isSubscribed: true, productName: "monthly", notification: .billingIssue))

        // "Auto-renew off, under 24 hours left | Yes | Expiry warning"
        func warning(in seconds: TimeInterval) -> EntitlementNotification? {
            evaluator.evaluate(snapshot(.active, expiresIn: seconds, autoRenew: false), order: subscriber, now: now)
                .notification
        }
        #expect(warning(in: 86_401) == nil)
        #expect(warning(in: 86_400) == .expiringToday)
        #expect(warning(in: 86_399) == .expiringToday)

        // Someone who is not subscribed is never sent "No subscription" for a retired product's renewal.
        let retired = Order(id: orderID, productName: "retired", isSubscribed: false)
        #expect(evaluator.evaluate(snapshot(.active, product: "retired"), order: retired, now: now).notification == nil)

        // A nil flag means not subscribed. This order already names the product, so only the flag
        // can explain the welcome, and a refund has nobody to tell.
        let unknown = Order(id: orderID, productName: "monthly", isSubscribed: nil)
        #expect(evaluator.evaluate(snapshot(.active), order: unknown, now: now).notification == .monthlyActive)
        #expect(evaluator.evaluate(snapshot(.revoked(.other)), order: unknown, now: now).notification == nil)
    }

    @Test func googleRevocationPassedToTheEngineIsAnnouncedAsCancelled() async throws {
        let store = RecordingStore()
        let notifier = RecordingNotifier()
        let engine = EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
        let revoked = GooglePlaySubscriptionPurchase(
            subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
            lineItems: [.init(productId: "monthly", expiryTime: "2027-02-01T00:00:00Z")])

        _ = try await engine.processGooglePlayPurchase(
            notifier: notifier, order: Order(id: orderID, productName: "monthly", isSubscribed: true),
            purchase: revoked, isRevoked: true)

        #expect(store.updates.map(\.order.isSubscribed) == [false])
        #expect(notifier.sent.map(\.collapseID) == ["cancelled"])
    }

    @Test func googleExpiryIsRequiredOnlyWhenAccessDependsOnItAndKeepsItsFraction() throws {
        func map(_ state: String, _ items: [GooglePlaySubscriptionPurchase.LineItem]?) throws -> SubscriptionSnapshot {
            try GooglePlayAdapter.snapshot(
                purchase: GooglePlaySubscriptionPurchase(subscriptionState: state, lineItems: items),
                catalog: catalog, held: nil, isRevoked: false, now: now)
        }

        // States that grant nothing must not need an expiry, or a pending purchase could never be read.
        for state in [
            "SUBSCRIPTION_STATE_PENDING", "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED",
            "SUBSCRIPTION_STATE_EXPIRED", "SUBSCRIPTION_STATE_ON_HOLD", "SUBSCRIPTION_STATE_PAUSED",
        ] {
            let withoutExpiry = try map(state, [.init(productId: "monthly")])
            #expect(withoutExpiry.productID == "monthly")
            #expect(withoutExpiry.expiresAt == nil)
            #expect(try map(state, nil).productID == "")
        }

        // A grace period grants access, so an unreadable expiry has to throw rather than end it.
        #expect(throws: EntitlementError.invalidDate(field: "expiryTime")) {
            try map("SUBSCRIPTION_STATE_IN_GRACE_PERIOD", [.init(productId: "monthly", expiryTime: "soon")])
        }

        // 2027-01-15T08:00:00Z is `now`.
        let precise = try map(
            "SUBSCRIPTION_STATE_ACTIVE", [.init(productId: "monthly", expiryTime: "2027-01-15T08:00:00.250Z")])
        #expect(precise.expiresAt == now.addingTimeInterval(0.25))
        let nanoseconds = try map(
            "SUBSCRIPTION_STATE_ACTIVE", [.init(productId: "monthly", expiryTime: "2027-01-15T08:00:00.123456789Z")])
        let offset = try #require(nanoseconds.expiresAt).timeIntervalSince(now)
        #expect(abs(offset - 0.123456789) < 0.000_001)
    }

    @Test func receiptPathEdgesMatchTheSignedDataPath() throws {
        func map(_ receipt: LatestReceiptInfo, _ renewal: PendingRenewalInfo) throws -> SubscriptionSnapshot {
            try AppleReceiptAdapter.snapshot(latestReceiptInfo: receipt, pendingRenewalInfo: renewal, now: now)
        }
        let justLapsed = milliseconds(now.addingTimeInterval(-60))

        // Expiry exactly now has lapsed, as on the signed path.
        let boundary = try map(
            LatestReceiptInfo(productId: "monthly", expiresDateMs: milliseconds(now)),
            PendingRenewalInfo(gracePeriodExpiresDateMs: milliseconds(now.addingTimeInterval(60))))
        #expect(boundary.lifecycle == .gracePeriod)

        // Renewal info that only names the subscription is still renewal info.
        let idOnly = try map(
            LatestReceiptInfo(productId: "monthly", originalTransactionId: "1", expiresDateMs: justLapsed),
            PendingRenewalInfo(originalTransactionId: "1"))
        #expect(idOnly.lifecycle == .active)

        // An empty grace date means there is none, the same as an empty cancellation date.
        let emptyGrace = try map(
            LatestReceiptInfo(productId: "monthly", expiresDateMs: justLapsed),
            PendingRenewalInfo(autoRenewStatus: "1", gracePeriodExpiresDateMs: "", isInBillingRetryPeriod: "1"))
        #expect(emptyGrace.lifecycle == .suspended(.billing))
    }

    @Test func malformedFlagsThrowAndAPastExpiryGivesAZeroTTL() async throws {
        // A malformed flag must not decode as "absent", which the rules read as a different state.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppStoreRenewalInfo.self, from: Data(#"{"autoRenewStatus":"on"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppStoreRenewalInfo.self, from: Data(#"{"isInBillingRetryPeriod":"yes"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AppStoreTransaction.self, from: Data(#"{"productId":"monthly","isUpgraded":"yes"}"#.utf8))
        }

        // FCM rejects a negative TTL, so an expiry that has already passed is sent as zero.
        let transport = RecordingTransport()
        let notifier = FCMEntitlementNotifier(
            projectID: "my-project", registrationToken: "device-1",
            accessTokenProvider: StaticToken(), transport: transport, now: { now })
        try await notifier.send(
            IAPPayload(title: "T", subtitle: "", body: ""), for: .cancelled, expiresAt: now.addingTimeInterval(-60))
        let call = try #require(transport.calls.first)
        let root = try #require(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        let message = try #require(root["message"] as? [String: Any])
        let android = try #require(message["android"] as? [String: Any])
        #expect(android["ttl"] as? String == "0s")
    }
}
