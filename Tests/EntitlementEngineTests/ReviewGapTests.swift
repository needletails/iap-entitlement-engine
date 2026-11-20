import APNSCore
import Crypto
import Foundation
import HTTPConnectionKit
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import IAPEntitlementEngine

/// Edges of the last round of changes that deliberate breakage showed no test was holding.
@Suite("Review gaps")
struct ReviewGapTests {
    /// The named-retired grant covers only the products the list names, never welcomes, and still reports a failing payment.
    @Test func namedRetiredGrantCoversOnlyNamedProductsAndAnnouncesOnlyAFailingPayment() async throws {
        let paidUntil = now.addingTimeInterval(30 * 86_400)
        let off = Order(id: orderID, productName: "monthly", isSubscribed: false)
        let renewing = AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 1, renewalDate: paidUntil)
        func engine(retired: Set<String>, store: RecordingStore = RecordingStore()) -> EntitlementEngine {
            // "monthly" has left the catalog. The slot now names "monthly.2026".
            EntitlementEngine(
                storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly.2026",
                yearlyProductID: "yearly", retiredProductIDs: retired, now: { now })
        }

        // A list that names other products does not let the holder of "monthly" back in.
        let lists: [Set<String>] = [["weekly.2024"], [""], ["monthly.2026"], ["Monthly"], ["monthly "]]
        for retired in lists {
            let store = RecordingStore()
            let notifier = RecordingNotifier()
            let result = try await engine(retired: retired, store: store).processAppStoreTransaction(
                notifier: notifier, order: off,
                transaction: AppStoreTransaction(productId: "monthly", originalTransactionId: "1", expiresDate: paidUntil),
                renewalInfo: renewing)
            #expect(result.order.isSubscribed == false, "retired list \(retired)")
            #expect(!result.didSave, "retired list \(retired)")
            #expect(result.accessExpiresAt == nil, "retired list \(retired)")
            #expect(store.updates.isEmpty, "retired list \(retired)")
            #expect(notifier.sent.isEmpty, "retired list \(retired)")
        }

        // The transaction of a recovered subscription can still carry the offer it began with.
        let named = engine(retired: ["monthly"])
        let trial = try await named.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: off,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: paidUntil,
                offerType: 1, offerDiscountType: "FREE_TRIAL"),
            renewalInfo: renewing)
        #expect(trial.order.isSubscribed == true)
        #expect(trial.notification == nil)
        let intro = try await named.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: off,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: paidUntil, offerType: 1),
            renewalInfo: renewing)
        #expect(intro.order.isSubscribed == true)
        #expect(intro.notification == nil)

        // The store reports a grace period for the order that was switched off.
        let grace = now.addingTimeInterval(3 * 86_400)
        let inGrace = try await named.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: off,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-60)),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, gracePeriodExpiresDate: grace,
                isInBillingRetryPeriod: true, renewalDate: now.addingTimeInterval(-60)))
        #expect(inGrace.order.isSubscribed == true)
        #expect(inGrace.accessExpiresAt == grace)
        #expect(inGrace.notification == .billingIssue)
    }

    /// The APNs client reports a failed connection and a malformed URL with this package's error, as the FCM transport does.
    @Test func apnsClientReportsTransportFailuresWithThisPackagesError() async {
        func failure(environmentURL: String) async -> (any Error)? {
            let client = HTTPConnectionAPNSClient(
                environment: .custom(url: environmentURL, port: 1), privateKey: .init(),
                keyIdentifier: "KEY123", teamIdentifier: "TEAM456", timeout: .seconds(5))
            let notifier = APNSEntitlementNotifier(client: client, topic: "com.example.app", deviceToken: "abcd")
            var caught: (any Error)?
            do {
                try await notifier.send(
                    IAPPayload(title: "T", subtitle: "", body: ""), for: .cancelled, expiresAt: now)
            } catch {
                caught = error
            }
            try? await client.shutdown()
            return caught
        }

        // Nothing listens on port 1.
        let refused = await failure(environmentURL: "http://127.0.0.1")
        #expect(refused is PushTransportError, "unexpected error \(String(describing: refused))")

        // "http://[:1/3/device/abcd" is not a URL.
        let malformed = await failure(environmentURL: "http://[")
        #expect(malformed as? PushTransportError == .invalidRequest, "unexpected error \(String(describing: malformed))")
    }

    /// Each of the four fields on its own marks a row that lost its product.
    @Test func receiptRowWithAnyOneFieldAndNoProductThrowsInsteadOfEndingAccess() async {
        let rows: [(name: String, row: LatestReceiptInfo)] = [
            ("transaction_id", LatestReceiptInfo(transactionId: "2")),
            ("original_transaction_id", LatestReceiptInfo(originalTransactionId: "1")),
            ("expires_date_ms", LatestReceiptInfo(expiresDateMs: milliseconds(now.addingTimeInterval(30 * 86_400)))),
            ("cancellation_date_ms", LatestReceiptInfo(cancellationDateMs: milliseconds(now.addingTimeInterval(-60)))),
        ]
        for (name, row) in rows {
            let store = RecordingStore()
            let notifier = RecordingNotifier()
            let engine = EntitlementEngine(
                storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
                yearlyProductID: "yearly", now: { now })
            await #expect(throws: EntitlementError.missingProductID, "row with only \(name)") {
                _ = try await engine.processReceipt(
                    notifier: notifier, order: Order(id: orderID, productName: "monthly", isSubscribed: true),
                    latestReceiptInfo: row,
                    pendingRenewalInfo: PendingRenewalInfo(originalTransactionId: "1", autoRenewStatus: "1"))
            }
            #expect(store.updates.isEmpty, "row with only \(name)")
            #expect(notifier.sent.isEmpty, "row with only \(name)")
        }
    }

    /// The comparisons of the earlier-period refund rule.
    @Test func earlierPeriodRefundRuleComparesTheRenewalDateStrictly() async throws {
        let engine = EntitlementEngine(
            storeDelegate: RecordingStore(), weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
        let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        // Its period ended ten days ago, and it was refunded a minute ago.
        let refunded = AppStoreTransaction(
            productId: "monthly", originalTransactionId: "1", expiresDate: tenDaysAgo,
            revocationDate: now.addingTimeInterval(-60), revocationReason: 0)
        func process(renewalDate: Date) async throws -> EntitlementResult {
            try await engine.processAppStoreTransaction(
                notifier: RecordingNotifier(), order: subscriber, transaction: refunded,
                renewalInfo: AppStoreRenewalInfo(
                    originalTransactionId: "1", autoRenewStatus: 0, isInBillingRetryPeriod: false,
                    renewalDate: renewalDate))
        }

        // SD14. The refunded transaction is the latest purchase, so this is a refund, and the
        // customer is told so.
        let latest = try await process(renewalDate: tenDaysAgo)
        #expect(latest.order.isSubscribed == false)
        #expect(latest.notification == .cancelled)

        // SD15. A renewal date before the transaction's own expiry names no later purchase.
        let stale = try await process(renewalDate: now.addingTimeInterval(-40 * 86_400))
        #expect(stale.order.isSubscribed == false)
        #expect(stale.notification == .cancelled)

        // SD16. A latest purchase that expires exactly now has run out, like every other expiry.
        let boundary = try await process(renewalDate: now)
        #expect(boundary.didSave)
        #expect(boundary.order.isSubscribed == false)
        #expect(boundary.notification == nil)

        // SD19. Once the latest purchase has run out, the snapshot is about that purchase, not
        // about the refunded one.
        let anHourAgo = now.addingTimeInterval(-3_600)
        let retrying = try AppStoreSignedDataAdapter.snapshot(
            transaction: refunded,
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, isInBillingRetryPeriod: true, renewalDate: anHourAgo),
            now: now)
        #expect(retrying.lifecycle == .suspended(.billing))
        #expect(retrying.expiresAt == anHourAgo)
        let lapsed = try AppStoreSignedDataAdapter.snapshot(
            transaction: refunded,
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 0, isInBillingRetryPeriod: false, renewalDate: anHourAgo),
            now: now)
        #expect(lapsed.lifecycle == .active)
        #expect(lapsed.expiresAt == anHourAgo)

        // SD18. While the latest purchase is still running, the refund concludes nothing.
        let running = try AppStoreSignedDataAdapter.snapshot(
            transaction: refunded,
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, isInBillingRetryPeriod: false,
                renewalDate: now.addingTimeInterval(20 * 86_400)),
            now: now)
        #expect(running.lifecycle == .pending)
        #expect(running.expiresAt == nil)

        // A billing retry is read first, as for every other period that has ended.
        let contradictory = try AppStoreSignedDataAdapter.snapshot(
            transaction: refunded,
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, isInBillingRetryPeriod: true,
                renewalDate: now.addingTimeInterval(20 * 86_400)),
            now: now)
        #expect(contradictory.lifecycle == .suspended(.billing))
    }

    /// What `wrapping` does with a cancellation, with HTTPConnectionKit's own invalidRequest, and with everything else.
    @Test func wrappingKeepsCancellationMapsAnUnusableRequestAndDescribesTheRest() async {
        // PT01. A cancelled send stays a CancellationError.
        #expect(PushTransportError.wrapping(CancellationError()) is CancellationError)

        // PT03. A URL that is not HTTP can never be sent, so it is refused as unusable rather
        // than reported as a connection that failed.
        await #expect(throws: PushTransportError.invalidRequest) {
            _ = try await HTTPConnectionFCMTransport().post(
                url: "ftp://fcm.googleapis.com/v1/projects/p/messages:send", headers: [:], body: Data())
        }

        // PT05. The description is what a log gets, so it has to say what went wrong.
        #expect(PushTransportError.wrapping(TestFailure.boom) as? PushTransportError == .connection(description: "boom"))
    }

    /// A Retry-After date is measured from the notifier's clock, not the wall clock.
    @Test func retryAfterDateIsMeasuredFromTheNotifiersClock() async {
        // `now` is Fri, 15 Jan 2027 08:00:00 GMT.
        let transport = RecordingTransport(
            status: 503, body: "nope", headers: ["Retry-After": "Fri, 15 Jan 2027 08:01:30 GMT"])
        let notifier = FCMEntitlementNotifier(
            projectID: "my-project", registrationToken: "device-1",
            accessTokenProvider: StaticToken(), transport: transport, now: { now })
        await #expect(throws: FCMError.requestFailed(status: 503, code: nil, retryAfter: 90, body: "nope")) {
            try await notifier.send(IAPPayload(title: "T", subtitle: "", body: ""), for: .cancelled, expiresAt: now)
        }
    }

    /// A result built from an order alone reports nothing else.
    @Test func resultBuiltFromAnOrderAloneReportsNothingElse() {
        let order = Order(id: orderID, productName: "monthly", isSubscribed: true)
        let result = EntitlementResult(order: order)
        #expect(result.order == order)
        #expect(!result.didSave)
        #expect(result.accessExpiresAt == nil)
        #expect(result.notification == nil)
        #expect(result.pushFailure == nil)
    }

    @Test func listingOneRetiredProductDoesNotLetAnotherHeldProductBackIn() async throws {
        let store = RecordingStore()
        let notifier = RecordingNotifier()
        // "monthly" is retired and listed. "cloud.storage" is a real subscription the customer
        // pays for, but it was never one of the plans and is not listed.
        let engine = EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly.2026",
            yearlyProductID: "yearly", retiredProductIDs: ["monthly"], now: { now })
        let paidUntil = now.addingTimeInterval(30 * 86_400)
        let other = Order(id: orderID, productName: "cloud.storage", isSubscribed: false)

        let signed = try await engine.processAppStoreTransaction(
            notifier: notifier, order: other,
            transaction: AppStoreTransaction(productId: "cloud.storage", originalTransactionId: "9", expiresDate: paidUntil),
            renewalInfo: AppStoreRenewalInfo(originalTransactionId: "9", autoRenewStatus: 1, renewalDate: paidUntil))
        #expect(signed.order.isSubscribed != true)
        #expect(signed.accessExpiresAt == nil)

        let receipt = try await engine.processReceipt(
            notifier: notifier, order: other,
            latestReceiptInfo: LatestReceiptInfo(
                productId: "cloud.storage", originalTransactionId: "9", expiresDateMs: milliseconds(paidUntil)),
            pendingRenewalInfo: PendingRenewalInfo(originalTransactionId: "9", autoRenewStatus: "1"))
        #expect(receipt.order.isSubscribed != true)

        let google = try await engine.processGooglePlayPurchase(
            notifier: notifier, order: other,
            purchase: GooglePlaySubscriptionPurchase(
                subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
                lineItems: [.init(
                    productId: "cloud.storage", expiryTime: "2027-02-14T08:00:00Z",
                    autoRenewingPlan: .init(autoRenewEnabled: true))]))
        #expect(google.order.isSubscribed != true)

        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }
}
