import APNSCore
import Foundation
import Testing
@testable import IAPEntitlementEngine

/// Edges that deliberate breakage of the 1.0 changes showed no test was holding in place.
@Suite("Hardening")
struct HardeningTests {
    @Test func accessExpiresAtIsNilWheneverThisCallDidNotFindAccessRunning() async throws {
        let engine = EntitlementEngine(
            storeDelegate: RecordingStore(), weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
        let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)
        // `now` is 2027-01-15T08:00:00Z, so this is thirty days ahead.
        let future = "2027-02-14T08:00:00Z"

        // Google reports a refund as EXPIRED and can leave expiryTime in the future.
        let revoked = try await engine.processGooglePlayPurchase(
            notifier: RecordingNotifier(), order: subscriber,
            purchase: GooglePlaySubscriptionPurchase(
                subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
                lineItems: [.init(productId: "monthly", expiryTime: future)]),
            isRevoked: true)
        #expect(revoked.order.isSubscribed == false)
        #expect(revoked.accessExpiresAt == nil)

        // Billing retry: access is off, so the lapsed period's date is not an access expiry.
        let retrying = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: subscriber,
            transaction: AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(-60)),
            renewalInfo: AppStoreRenewalInfo(autoRenewStatus: 1, isInBillingRetryPeriod: true))
        #expect(retrying.order.isSubscribed == false)
        #expect(retrying.accessExpiresAt == nil)

        // A running purchase of another product says nothing about this order's access.
        let other = try await engine.processGooglePlayPurchase(
            notifier: RecordingNotifier(), order: subscriber,
            purchase: GooglePlaySubscriptionPurchase(
                subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
                lineItems: [.init(
                    productId: "another-product", expiryTime: future,
                    autoRenewingPlan: .init(autoRenewEnabled: true))]))
        #expect(!other.didSave)
        #expect(other.accessExpiresAt == nil)
    }

    @Test func renewalDateRuleLeavesARunningPeriodAGracePeriodAndADateThatHasPassedAlone() async throws {
        let engine = EntitlementEngine(
            storeDelegate: RecordingStore(), weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
        let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)
        let expiry = now.addingTimeInterval(30 * 86_400)
        let lapsed = AppStoreTransaction(
            productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-60))

        // What Apple sends for every running subscription: renewalDate is the expiry of the
        // latest purchase, and the latest purchase is this transaction.
        let started = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: Order(id: orderID),
            transaction: AppStoreTransaction(productId: "monthly", originalTransactionId: "1", expiresDate: expiry),
            renewalInfo: AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 1, renewalDate: expiry))
        #expect(started.order.isSubscribed == true)
        #expect(started.accessExpiresAt == expiry)
        #expect(started.notification == .monthlyActive)

        // A grace period on the latest purchase, whose expiry is the renewal date Apple sends.
        let grace = now.addingTimeInterval(3 * 86_400)
        let inGrace = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: subscriber, transaction: lapsed,
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, gracePeriodExpiresDate: grace,
                renewalDate: now.addingTimeInterval(-60)))
        #expect(inGrace.notification == .billingIssue)
        #expect(inGrace.accessExpiresAt == grace)

        // A renewal date of exactly now has passed, like every other expiry the engine reads.
        let ended = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: subscriber, transaction: lapsed,
            renewalInfo: AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 0, renewalDate: now))
        #expect(ended.order.isSubscribed == false)
    }

    @Test func receiptPathActsOnAHeldRetiredProductAndOnAnEmptyReceipt() async throws {
        // "monthly" used to fill the monthly slot, and the order still holds it.
        let engine = EntitlementEngine(
            storeDelegate: RecordingStore(), weeklyProductID: "weekly", monthlyProductID: "monthly.2026",
            yearlyProductID: "yearly", now: { now })
        let holder = Order(id: orderID, productName: "monthly", isSubscribed: true)

        let refunded = try await engine.processReceipt(
            notifier: RecordingNotifier(), order: holder,
            latestReceiptInfo: LatestReceiptInfo(
                productId: "monthly", expiresDateMs: milliseconds(now.addingTimeInterval(86_400)),
                cancellationDateMs: milliseconds(now.addingTimeInterval(-60)), cancellationReason: "0"),
            pendingRenewalInfo: PendingRenewalInfo(autoRenewStatus: "0"))
        #expect(refunded.didSave)
        #expect(refunded.order.isSubscribed == false)
        #expect(refunded.notification == .cancelled)

        // A receipt with no rows names no product, and still means "no subscription".
        let empty = try await engine.processReceipt(
            notifier: RecordingNotifier(), order: holder,
            latestReceiptInfo: LatestReceiptInfo(), pendingRenewalInfo: PendingRenewalInfo())
        #expect(empty.order.isSubscribed == false)
        #expect(empty.notification == .notSubscribed)
    }

    @Test func onlyARefundAfterThePeriodEndedCanBeAnEarlierPeriod() async throws {
        let store = RecordingStore()
        let engine = EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
        let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)
        let inTwentyDays = now.addingTimeInterval(20 * 86_400)

        // A refund of the running period ends access whatever renewalDate says. An extended
        // renewal date can be later than this transaction's own expiresDate, which never changes.
        let running = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: subscriber,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: inTwentyDays,
                revocationDate: now.addingTimeInterval(-60), revocationReason: 0),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 0, renewalDate: inTwentyDays.addingTimeInterval(30 * 86_400)))
        #expect(running.order.isSubscribed == false)
        #expect(running.notification == .cancelled)

        // A refund stamped at the instant the period ended is a refund of an ended period.
        let ended = now.addingTimeInterval(-10 * 86_400)
        let boundary = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: subscriber,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: ended,
                revocationDate: ended, revocationReason: 0),
            renewalInfo: AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 1, renewalDate: inTwentyDays))
        #expect(!boundary.didSave)
        #expect(boundary.notification == nil)

        // "A later purchase" means later than this transaction, not still running. In a grace
        // period the latest purchase has already expired, and the customer keeps access.
        let inGrace = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: subscriber,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-40 * 86_400),
                revocationDate: now.addingTimeInterval(-60), revocationReason: 0),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1,
                gracePeriodExpiresDate: now.addingTimeInterval(3 * 86_400), isInBillingRetryPeriod: true,
                renewalDate: now.addingTimeInterval(-2 * 86_400)))
        #expect(!inGrace.didSave)
        #expect(inGrace.order.isSubscribed == true)
    }

    @Test func fcmFailureReadsALowerCaseRetryAfterAndAnErrorCodeThatIsNotTheFirstDetail() async {
        let payload = IAPPayload(title: "T", subtitle: "", body: "")
        func notifier(_ transport: RecordingTransport) -> FCMEntitlementNotifier {
            FCMEntitlementNotifier(
                projectID: "my-project", registrationToken: "device-1",
                accessTokenProvider: StaticToken(), transport: transport, now: { now })
        }

        // HTTPConnectionFCMTransport hands header names over in lower case.
        let quota = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"QUOTA_EXCEEDED"}]}}"#
        await #expect(throws: FCMError.requestFailed(status: 429, code: "QUOTA_EXCEEDED", retryAfter: 30, body: quota)) {
            try await notifier(RecordingTransport(status: 429, body: quota, headers: ["retry-after": "30"]))
                .send(payload, for: .cancelled, expiresAt: now)
        }

        // Google documents a QuotaFailure extension on QUOTA_EXCEEDED, so `details` is a list and
        // the FcmError entry need not be the first one in it.
        let listed = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[]},{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"QUOTA_EXCEEDED"}]}}"#
        await #expect(throws: FCMError.requestFailed(status: 429, code: "QUOTA_EXCEEDED", retryAfter: nil, body: listed)) {
            try await notifier(RecordingTransport(status: 429, body: listed)).send(payload, for: .cancelled, expiresAt: now)
        }
    }

    @Test func lineItemThatNamesNoProductIsNeverTheHeldPlanAndEndsAccessWithAMessage() async throws {
        let engine = EntitlementEngine(
            storeDelegate: RecordingStore(), weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
        let nameless = GooglePlaySubscriptionPurchase.LineItem(productId: "", expiryTime: "2030-01-01T00:00:00Z")

        // `Order.init` defaults productName to "", which must not match an item with no product.
        let started = try await engine.processGooglePlayPurchase(
            notifier: RecordingNotifier(), order: Order(id: orderID),
            purchase: GooglePlaySubscriptionPurchase(
                subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
                lineItems: [
                    .init(
                        productId: "monthly", expiryTime: "2027-02-14T08:00:00Z",
                        autoRenewingPlan: .init(autoRenewEnabled: true)),
                    nameless,
                ]))
        #expect(started.order.isSubscribed == true)
        #expect(started.order.productName == "monthly")

        // A running purchase that names no product at all is not one of the three plans.
        let ended = try await engine.processGooglePlayPurchase(
            notifier: RecordingNotifier(), order: Order(id: orderID, productName: "monthly", isSubscribed: true),
            purchase: GooglePlaySubscriptionPurchase(subscriptionState: "SUBSCRIPTION_STATE_ACTIVE", lineItems: [nameless]))
        #expect(ended.order.isSubscribed == false)
        #expect(ended.notification == .notSubscribed)
    }

    @Test func receiptRowWithOnlyAProductDecodes() throws {
        let row = try JSONDecoder().decode(LatestReceiptInfo.self, from: Data(#"{"product_id":"coins.100"}"#.utf8))
        #expect(row.productId == "coins.100")
        #expect(row.originalTransactionId == "")
        #expect(row.transactionId == "")
        #expect(row.quantity == "")
        #expect(row.isTrialPeriod == "")
        #expect(row.purchaseDateMs == "")
    }

    @Test func onlyAnExplicitPendingStateNeedsAcknowledgement() {
        #expect(!GooglePlaySubscriptionPurchase(subscriptionState: "SUBSCRIPTION_STATE_ACTIVE").needsAcknowledgement)
        #expect(!GooglePlaySubscriptionPurchase(
            subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
            acknowledgementState: "ACKNOWLEDGEMENT_STATE_UNSPECIFIED").needsAcknowledgement)
    }
}
