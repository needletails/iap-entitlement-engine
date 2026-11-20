import APNSCore
import Foundation
import Testing
@testable import IAPEntitlementEngine

/// A product that has left the three plans but still has subscribers, named by the app.
@Suite("Named retired products")
struct NamedRetiredProductTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()
    let lapsed = now.addingTimeInterval(-3_600)
    let paidUntil = now.addingTimeInterval(30 * 86_400)
    let holder = Order(id: orderID, productName: "monthly", isSubscribed: true)

    /// "monthly" has left the catalog. The slot now names "monthly.2026".
    func engine(retired: Set<String> = ["monthly"]) -> EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly.2026",
            yearlyProductID: "yearly", retiredProductIDs: retired, now: { now })
    }

    func retrying() -> (AppStoreTransaction, AppStoreRenewalInfo) {
        (AppStoreTransaction(productId: "monthly", originalTransactionId: "1", expiresDate: lapsed),
         AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 1, isInBillingRetryPeriod: true, renewalDate: lapsed))
    }

    func recovered() -> (AppStoreTransaction, AppStoreRenewalInfo) {
        (AppStoreTransaction(productId: "monthly", originalTransactionId: "1", expiresDate: paidUntil),
         AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 1, isInBillingRetryPeriod: false, renewalDate: paidUntil))
    }

    /// The card fails, Apple retries, and the charge goes through. The customer is paying again.
    @Test func subscriberGetsAccessBackAfterBillingRecovery() async throws {
        let failed = try await engine().processAppStoreTransaction(
            notifier: notifier, order: holder, transaction: retrying().0, renewalInfo: retrying().1)
        #expect(failed.order.isSubscribed == false)
        #expect(failed.notification == .billingIssue)

        let back = try await engine().processAppStoreTransaction(
            notifier: notifier, order: failed.order, transaction: recovered().0, renewalInfo: recovered().1)
        #expect(back.order.isSubscribed == true)
        #expect(back.order.productName == "monthly")
        #expect(back.accessExpiresAt == paidUntil)
        // There is no plan to announce for a product that is no longer sold.
        #expect(back.notification == nil)
    }

    /// Without the list a suspension is final, because nothing but the order says the product
    /// was ever sold, and an order is something the caller can write.
    @Test func unnamedRetiredProductStaysOffAfterASuspension() async throws {
        let failed = try await engine(retired: []).processAppStoreTransaction(
            notifier: notifier, order: holder, transaction: retrying().0, renewalInfo: retrying().1)
        let back = try await engine(retired: []).processAppStoreTransaction(
            notifier: notifier, order: failed.order, transaction: recovered().0, renewalInfo: recovered().1)
        #expect(back.order.isSubscribed == false)
        #expect(!back.didSave)
    }

    /// Naming a product lets its own subscribers back in. It does not put it back on sale.
    @Test(arguments: [String?.none, "", "yearly"])
    func namedRetiredProductNeverStartsForAnOrderThatDoesNotHoldIt(product: String?) async throws {
        let result = try await engine().processAppStoreTransaction(
            notifier: notifier, order: Order(id: orderID, productName: product, isSubscribed: false),
            transaction: recovered().0, renewalInfo: recovered().1)
        #expect(result.order.isSubscribed != true)
        #expect(!result.didSave)
        #expect(notifier.sent.isEmpty)
    }

    @Test func receiptPathRecoversTheSameWay() async throws {
        let off = Order(id: orderID, productName: "monthly", isSubscribed: false)
        let back = try await engine().processReceipt(
            notifier: notifier, order: off,
            latestReceiptInfo: LatestReceiptInfo(
                productId: "monthly", originalTransactionId: "1", expiresDateMs: milliseconds(paidUntil)),
            pendingRenewalInfo: PendingRenewalInfo(originalTransactionId: "1", autoRenewStatus: "1"))
        #expect(back.order.isSubscribed == true)
        #expect(back.notification == nil)
    }

    /// A retired base plan under a Play product that is still sold, after an account hold.
    @Test func googleBasePlanRecoversAfterAnAccountHold() async throws {
        func purchase(_ state: String, expiry: String) throws -> GooglePlaySubscriptionPurchase {
            let json = #"""
            {"subscriptionState":"\#(state)","lineItems":[{"productId":"premium","expiryTime":"\#(expiry)",
              "autoRenewingPlan":{"autoRenewEnabled":true},"offerDetails":{"basePlanId":"monthly"}}]}
            """#
            return try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
        }
        let held = try await engine().processGooglePlayPurchase(
            notifier: notifier, order: holder, purchase: purchase("SUBSCRIPTION_STATE_ON_HOLD", expiry: "2027-01-15T07:00:00Z"))
        #expect(held.order.isSubscribed == false)

        let back = try await engine().processGooglePlayPurchase(
            notifier: notifier, order: held.order,
            purchase: purchase("SUBSCRIPTION_STATE_ACTIVE", expiry: "2027-02-14T08:00:00Z"))
        #expect(back.order.isSubscribed == true)
        #expect(back.order.productName == "monthly")
        #expect(back.accessExpiresAt == paidUntil)
    }
}

@Suite("Review fixes")
struct ReviewFixTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()
    let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)

    var engine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
    }

    /// The subscription ran out ten days ago and the order missed it. Apple then refunds an
    /// earlier month. Its renewal info says the latest purchase is over, so access ends.
    @Test func refundOfAnEarlierPeriodAfterTheSubscriptionLapsedEndsAccess() async throws {
        let result = try await engine.processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-40 * 86_400),
                revocationDate: now.addingTimeInterval(-60), revocationReason: 0),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 0, isInBillingRetryPeriod: false,
                renewalDate: now.addingTimeInterval(-10 * 86_400)))
        #expect(result.order.isSubscribed == false)
        // The refunded period was not the one that ended access, so nobody is told "cancelled".
        #expect(result.notification == nil)
    }

    @Test func refundOfAnEarlierPeriodDuringBillingRetryEndsAccessAndAsksForPayment() async throws {
        let result = try await engine.processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-40 * 86_400),
                revocationDate: now.addingTimeInterval(-60), revocationReason: 0),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, isInBillingRetryPeriod: true,
                renewalDate: now.addingTimeInterval(-3_600)))
        #expect(result.order.isSubscribed == false)
        #expect(result.notification == .billingIssue)
    }

    /// The receipt twin of the signed-data rule: a row that lost its product in the caller's
    /// mapping must not read as "Apple returned no purchase".
    @Test func receiptRowThatLostItsProductThrowsInsteadOfEndingAccess() async {
        await #expect(throws: EntitlementError.missingProductID) {
            _ = try await engine.processReceipt(
                notifier: notifier, order: subscriber,
                latestReceiptInfo: LatestReceiptInfo(
                    transactionId: "2", originalTransactionId: "1",
                    expiresDateMs: milliseconds(now.addingTimeInterval(30 * 86_400))),
                pendingRenewalInfo: PendingRenewalInfo(originalTransactionId: "1", autoRenewStatus: "1"))
        }
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    @Test func emptyReceiptRowStillMeansNoSubscription() async throws {
        let result = try await engine.processReceipt(
            notifier: notifier, order: subscriber,
            latestReceiptInfo: LatestReceiptInfo(), pendingRenewalInfo: PendingRenewalInfo())
        #expect(result.order.isSubscribed == false)
        #expect(result.notification == .notSubscribed)
    }

    /// A caller holds clients as `any APNSClientProtocol`, for example to swap one in tests.
    @Test func notifierTakesAnExistentialClient() async throws {
        let client = FakeAPNSClient()
        let anyClient: any APNSClientProtocol = client
        let notifier = APNSEntitlementNotifier(client: anyClient, topic: "com.example.app", deviceToken: "abcd")
        try await notifier.send(
            IAPPayload(title: "T", subtitle: "", body: ""), for: .cancelled, expiresAt: now.addingTimeInterval(60))
        #expect(client.requests.first?.collapseID == "cancelled")
        #expect(client.requests.first?.priority == 10)
    }

    /// The result names the notification, and the messages give its copy, so a failed push can
    /// be sent again.
    @Test func failedPushCanBeResentWithTheSameCopy() async throws {
        var messages = EntitlementMessages()
        messages.monthlyActive = IAPPayload(title: "Welcome", subtitle: "", body: "")
        let engine = EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", messages: messages, now: { now })
        let result = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(failure: TestFailure.boom), order: Order(id: orderID),
            transaction: AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(86_400 * 30)),
            renewalInfo: AppStoreRenewalInfo(autoRenewStatus: 1))
        let due = try #require(result.notification)
        #expect(result.pushFailure != nil)
        #expect(messages.payload(for: due).title == "Welcome")
    }

    @Test func resultCanBeBuiltForATestDouble() {
        let result = EntitlementResult(order: subscriber, accessExpiresAt: now, notification: .billingIssue)
        #expect(result.order == subscriber)
        #expect(!result.didSave)
        #expect(result.accessExpiresAt == now)
        #expect(result.pushFailure == nil)
    }
}

@Suite("Final review fixes")
struct FinalReviewFixTests {
    var engine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: RecordingStore(), weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
    }

    /// The subscriber moved from monthly to yearly long ago. The yearly period ran out yesterday
    /// and is in a grace period. Apple now refunds one of the old monthly periods.
    @Test func refundOfAPeriodOnAProductTheSubscriberLeftKeepsTheOrdersProduct() async throws {
        let engine = engine
        let onYearly = Order(id: orderID, productName: "yearly", isSubscribed: true)
        let refund = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: onYearly,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-400 * 86_400),
                revocationDate: now.addingTimeInterval(-60), revocationReason: 0),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1,
                gracePeriodExpiresDate: now.addingTimeInterval(3 * 86_400), isInBillingRetryPeriod: true,
                renewalDate: now.addingTimeInterval(-86_400)))
        #expect(refund.order.isSubscribed == true)
        #expect(refund.order.productName == "yearly")
        #expect(!refund.didSave)

        // The payment then goes through, and the yearly plan renews.
        let nextYear = now.addingTimeInterval(365 * 86_400)
        let renewed = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: refund.order,
            transaction: AppStoreTransaction(productId: "yearly", originalTransactionId: "1", expiresDate: nextYear),
            renewalInfo: AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 1, renewalDate: nextYear))
        #expect(renewed.order.productName == "yearly")
        // A subscriber of several years is not welcomed to the yearly plan.
        #expect(renewed.notification == nil)
    }

    /// The same for a declined refund or a consumption request about an old period.
    @Test func earlierPeriodOnAProductTheSubscriberLeftKeepsTheOrdersProductDuringGrace() async throws {
        let onYearly = Order(id: orderID, productName: "yearly", isSubscribed: true)
        let result = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: onYearly,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-400 * 86_400)),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1,
                gracePeriodExpiresDate: now.addingTimeInterval(3 * 86_400), isInBillingRetryPeriod: true,
                renewalDate: now.addingTimeInterval(-86_400)))
        #expect(result.order == onYearly)
        #expect(!result.didSave)
    }

    /// The subscription's own latest period still starts a grace period as before.
    @Test func latestPeriodStillEntersGrace() async throws {
        let grace = now.addingTimeInterval(3 * 86_400)
        let lapsed = now.addingTimeInterval(-3_600)
        let result = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: Order(id: orderID, productName: "monthly", isSubscribed: true),
            transaction: AppStoreTransaction(productId: "monthly", originalTransactionId: "1", expiresDate: lapsed),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, gracePeriodExpiresDate: grace,
                isInBillingRetryPeriod: true, renewalDate: lapsed))
        #expect(result.order.isSubscribed == true)
        #expect(result.accessExpiresAt == grace)
        #expect(result.notification == .billingIssue)
    }

    /// Once the grace period is over, an earlier period ends access like any other lapse.
    @Test func earlierPeriodEndsAccessOnceTheGracePeriodIsOver() async throws {
        let result = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: Order(id: orderID, productName: "yearly", isSubscribed: true),
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-400 * 86_400)),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1,
                gracePeriodExpiresDate: now.addingTimeInterval(-60), isInBillingRetryPeriod: false,
                renewalDate: now.addingTimeInterval(-20 * 86_400)))
        #expect(result.order.isSubscribed == false)
        #expect(result.order.productName == "yearly")
    }

    /// Only an empty row means Apple returned no purchase, whichever field survived the mapping.
    @Test(arguments: [
        LatestReceiptInfo(transactionId: "2"),
        LatestReceiptInfo(originalTransactionId: "1"),
        LatestReceiptInfo(expiresDateMs: "1800000000000"),
        LatestReceiptInfo(cancellationDateMs: "1800000000000"),
        LatestReceiptInfo(purchaseDateMs: "1800000000000", webOrderLineItemId: "9"),
        LatestReceiptInfo(expiresDate: "2027-02-14 08:00:00 Etc/GMT"),
        LatestReceiptInfo(isUpgraded: "true"),
        LatestReceiptInfo(quantity: "1", isTrialPeriod: "false", subscriptionGroupIdentifier: "4"),
    ])
    func receiptRowWithAnyFieldButNoProductThrows(row: LatestReceiptInfo) async {
        let store = RecordingStore()
        let engine = EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
        await #expect(throws: EntitlementError.missingProductID) {
            _ = try await engine.processReceipt(
                notifier: RecordingNotifier(), order: Order(id: orderID, productName: "monthly", isSubscribed: true),
                latestReceiptInfo: row,
                pendingRenewalInfo: PendingRenewalInfo(originalTransactionId: "1", autoRenewStatus: "1"))
        }
        #expect(store.updates.isEmpty)
    }
}

/// What the last independent sweep of the Apple rules turned up.
@Suite("Earlier periods and grace")
struct EarlierPeriodGraceTests {
    var engine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: RecordingStore(), weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
    }
    let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)
    let earlier = AppStoreTransaction(
        productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-40 * 86_400))
    var refundedEarlier: AppStoreTransaction {
        AppStoreTransaction(
            productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-40 * 86_400),
            revocationDate: now.addingTimeInterval(-60), revocationReason: 0)
    }

    /// A grace date left over from an old payment failure must not end a subscription that is
    /// paid up, whichever kind of notice about an old period carries it.
    @Test func leftoverGraceDateDoesNotEndAPaidUpSubscription() async throws {
        let paidUp = AppStoreRenewalInfo(
            originalTransactionId: "1", autoRenewStatus: 1,
            gracePeriodExpiresDate: now.addingTimeInterval(-5 * 86_400), isInBillingRetryPeriod: false,
            renewalDate: now.addingTimeInterval(20 * 86_400))
        for transaction in [refundedEarlier, earlier] {
            let result = try await engine.processAppStoreTransaction(
                notifier: RecordingNotifier(), order: subscriber, transaction: transaction, renewalInfo: paidUp)
            #expect(result.order.isSubscribed == true)
            #expect(!result.didSave)
            #expect(result.notification == nil)
        }
    }

    /// A notice about an old period that arrives during a grace period still keeps the
    /// subscriber's access, asks for payment and reports when the grace period ends.
    @Test func earlierPeriodDuringGraceKeepsAccessAndAsksForPayment() async throws {
        let grace = now.addingTimeInterval(6 * 86_400)
        let inGrace = AppStoreRenewalInfo(
            originalTransactionId: "1", autoRenewStatus: 1, gracePeriodExpiresDate: grace,
            isInBillingRetryPeriod: true, renewalDate: now.addingTimeInterval(-10 * 86_400))
        for transaction in [refundedEarlier, earlier] {
            let result = try await engine.processAppStoreTransaction(
                notifier: RecordingNotifier(), order: subscriber, transaction: transaction, renewalInfo: inGrace)
            #expect(result.order == subscriber)
            #expect(!result.didSave)
            #expect(result.notification == .billingIssue)
            #expect(result.accessExpiresAt == grace)
        }
    }

    /// An old period cannot start a subscription, because nothing says which product it is on.
    @Test func earlierPeriodDuringGraceDoesNotStartASubscription() async throws {
        let inGrace = AppStoreRenewalInfo(
            originalTransactionId: "1", autoRenewStatus: 1,
            gracePeriodExpiresDate: now.addingTimeInterval(6 * 86_400), isInBillingRetryPeriod: true,
            renewalDate: now.addingTimeInterval(-10 * 86_400))
        let off = Order(id: orderID, productName: "monthly", isSubscribed: false)
        let result = try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), order: off, transaction: earlier, renewalInfo: inGrace)
        #expect(result.order == off)
        #expect(result.notification == nil)
        #expect(result.accessExpiresAt == nil)
    }

    /// "No purchase" is an empty row whether a mapping wrote its optional fields as nil or "".
    @Test(arguments: [
        LatestReceiptInfo(cancellationDateMs: ""),
        LatestReceiptInfo(cancellationDate: "", cancellationDatePst: "", cancellationReason: "", isUpgraded: ""),
        LatestReceiptInfo(offerCodeRefName: "", promotionalOfferId: ""),
    ])
    func emptyRowWithEmptyOptionalFieldsStillMeansNoSubscription(row: LatestReceiptInfo) async throws {
        let result = try await engine.processReceipt(
            notifier: RecordingNotifier(), order: subscriber,
            latestReceiptInfo: row, pendingRenewalInfo: PendingRenewalInfo())
        #expect(result.order.isSubscribed == false)
        #expect(result.notification == .notSubscribed)
    }

    /// A request that can never be sent is reported as that, not as a connection worth retrying.
    @Test(arguments: ["api.push.example.com/3/device/x", "ftp://127.0.0.1/x", "https:///x", "https://host:0/x", "https://host:70000/x", ""])
    func urlThatCanNeverBeSentIsAnInvalidRequest(text: String) {
        #expect(throws: PushTransportError.invalidRequest) { try PushTransportError.usable(URL(string: text)) }
    }

    @Test(arguments: ["https://api.push.apple.com/3/device/abcd", "HTTPS://fcm.googleapis.com/v1/x", "http://127.0.0.1:8080/send"])
    func ordinaryURLIsUsable(text: String) throws {
        #expect(try PushTransportError.usable(URL(string: text)).absoluteString == text)
    }
}
