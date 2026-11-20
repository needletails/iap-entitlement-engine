import Foundation
import Testing
@testable import IAPEntitlementEngine

/// Inputs that are not about this order's subscription, or that say too little to act on.
@Suite("Rule edges")
struct RuleEdgeTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()
    let future = now.addingTimeInterval(86_400 * 30)
    let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)

    func engine(weekly: String = "weekly") -> EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: weekly, monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
    }

    // MARK: Other products

    /// A consumable has no expiry. It used to throw `invalidDate`, which a webhook answers
    /// with a failure, so the store kept redelivering it.
    @Test func oneTimePurchaseOfAnotherProductLeavesTheOrderAlone() async throws {
        let result = try await engine().processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(productId: "coins.100"), renewalInfo: AppStoreRenewalInfo())
        #expect(!result.didSave)
        #expect(notifier.sent.isEmpty)
    }

    @Test func lapsedOtherSubscriptionWithoutRenewalInfoLeavesTheOrderAlone() async throws {
        let result = try await engine().processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(productId: "other.monthly", expiresDate: now.addingTimeInterval(-60)),
            renewalInfo: AppStoreRenewalInfo())
        #expect(!result.didSave)
    }

    @Test func receiptForAnotherProductWithNoExpiryLeavesTheOrderAlone() async throws {
        let result = try await engine().processReceipt(
            notifier: notifier, order: subscriber,
            latestReceiptInfo: LatestReceiptInfo(productId: "coins.100"), pendingRenewalInfo: PendingRenewalInfo())
        #expect(!result.didSave)
        #expect(notifier.sent.isEmpty)
    }

    /// The same gap on a product the catalog sells is still an error, never a guess.
    @Test func catalogProductWithNoExpiryStillThrows() async {
        await #expect(throws: EntitlementError.invalidDate(field: "expiresDate")) {
            _ = try await engine().processAppStoreTransaction(
                notifier: notifier, order: subscriber,
                transaction: AppStoreTransaction(productId: "monthly"), renewalInfo: AppStoreRenewalInfo())
        }
        #expect(store.updates.isEmpty)
    }

    // MARK: No subscription

    @Test func emptyTransactionMeansNoSubscription() async throws {
        let result = try await engine().processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(), renewalInfo: AppStoreRenewalInfo())
        #expect(result.order.isSubscribed == false)
        #expect(result.notification == .notSubscribed)
    }

    /// Only a value with nothing in it means "Apple returned no transactions". One that lost
    /// its product on the way is a mapping bug, and must not end a paid subscription.
    @Test(arguments: [
        AppStoreTransaction(expiresDate: now.addingTimeInterval(86_400)),
        AppStoreTransaction(productId: "", originalTransactionId: "1"),
        AppStoreTransaction(productId: ""),
    ])
    func transactionThatLostItsProductThrowsInsteadOfEndingAccess(transaction: AppStoreTransaction) async {
        await #expect(throws: EntitlementError.missingProductID) {
            _ = try await engine().processAppStoreTransaction(
                notifier: notifier, order: subscriber, transaction: transaction, renewalInfo: AppStoreRenewalInfo())
        }
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    // MARK: An earlier billing period

    /// REFUND_DECLINED and CONSUMPTION_REQUEST carry the transaction they are about, which can
    /// be last month's. Apple's renewal info says the latest purchase is still running.
    @Test func earlierPeriodLeavesASubscriptionAloneWhileTheLatestPurchaseRuns() async throws {
        let result = try await engine().processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-10 * 86_400)),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, renewalDate: now.addingTimeInterval(20 * 86_400)))
        #expect(!result.didSave)
        #expect(notifier.sent.isEmpty)
    }

    @Test func earlierPeriodNeverStartsASubscription() async throws {
        let result = try await engine().processAppStoreTransaction(
            notifier: notifier, order: Order(id: orderID),
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-10 * 86_400)),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, renewalDate: now.addingTimeInterval(20 * 86_400)))
        #expect(!result.didSave)
        #expect(result.order.isSubscribed != true)
    }

    /// Once the latest purchase has run out as well, a lapsed transaction ends access as before.
    @Test func lapsedTransactionEndsAccessOnceTheLatestPurchaseHasRunOutToo() async throws {
        let result = try await engine().processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: now.addingTimeInterval(-10 * 86_400)),
            renewalInfo: AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 0, renewalDate: now.addingTimeInterval(-60)))
        #expect(result.order.isSubscribed == false)
    }

    @Test func lapsedTransactionEndsAccessWhenAppleGivesNoRenewalDate() async throws {
        let result = try await engine().processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(-60)),
            renewalInfo: AppStoreRenewalInfo(autoRenewStatus: 0))
        #expect(result.order.isSubscribed == false)
    }

    /// Billing retry means the latest purchase has already ended, whatever date is attached.
    @Test func billingRetryIsNotMistakenForAnEarlierPeriod() async throws {
        let result = try await engine().processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(-60)),
            renewalInfo: AppStoreRenewalInfo(
                autoRenewStatus: 1, isInBillingRetryPeriod: true, renewalDate: now.addingTimeInterval(86_400)))
        #expect(result.order.isSubscribed == false)
        #expect(result.notification == .billingIssue)
    }

    // MARK: Catalog

    /// An app with no weekly plan passes "" for it, and "" must not become a product.
    @Test func emptySlotIsNotACatalogProduct() async throws {
        let json = #"""
        {"subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","lineItems":[
          {"productId":"anything","expiryTime":"2027-02-14T08:00:00Z","offerDetails":{"basePlanId":""}}]}
        """#
        let purchase = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
        let result = try await engine(weekly: "").processGooglePlayPurchase(
            notifier: notifier, order: Order(id: orderID), purchase: purchase)
        #expect(!result.didSave)
        #expect(result.order.isSubscribed != true)
        #expect(notifier.sent.isEmpty)
        #expect(!ProductCatalog(weekly: "", monthly: "monthly", yearly: "yearly").contains(""))
    }

    // MARK: Orders written by something else

    /// An order saved as subscribed without its product is adopted, not welcomed a second time.
    @Test(arguments: [String?.none, ""])
    func subscriberWhoseOrderNamesNoProductIsNotWelcomedAgain(product: String?) {
        let decision = EntitlementEvaluator(catalog: catalog).evaluate(
            SubscriptionSnapshot(
                productID: "monthly", lifecycle: .active, expiresAt: future, autoRenewEnabled: true, offer: .none),
            order: Order(id: orderID, productName: product, isSubscribed: true), now: now)
        #expect(decision == .init(isSubscribed: true, productName: "monthly", notification: nil))
    }
}

@Suite("Receipt decoding")
struct ReceiptDecodingTests {
    /// `latest_receipt_info` lists every purchase, and only subscriptions carry these keys.
    @Test func rowForANonSubscriptionPurchaseDecodes() throws {
        let json = #"""
        {"quantity":"1","product_id":"coins.100","transaction_id":"7","original_transaction_id":"7",
         "purchase_date":"x","purchase_date_ms":"1","purchase_date_pst":"x","original_purchase_date":"x",
         "original_purchase_date_ms":"1","original_purchase_date_pst":"x","is_trial_period":"false",
         "in_app_ownership_type":"PURCHASED"}
        """#
        let row = try JSONDecoder().decode(LatestReceiptInfo.self, from: Data(json.utf8))
        #expect(row.productId == "coins.100")
        #expect(row.expiresDateMs == "")
        #expect(row.subscriptionGroupIdentifier == "")
    }

    @Test func rowWithNoProductStillThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LatestReceiptInfo.self, from: Data(#"{"quantity":"1"}"#.utf8))
        }
    }

    @Test func receiptRowsSurviveARoundTrip() throws {
        let row = LatestReceiptInfo(
            productId: "monthly", originalTransactionId: "1", expiresDateMs: "1800000000000",
            cancellationDateMs: "1799000000000", cancellationReason: "1", isUpgraded: "true")
        let decoded = try JSONDecoder().decode(LatestReceiptInfo.self, from: JSONEncoder().encode(row))
        #expect(decoded.productId == "monthly")
        #expect(decoded.expiresDateMs == "1800000000000")
        #expect(decoded.cancellationDateMs == "1799000000000")
        #expect(decoded.cancellationReason == "1")
        #expect(decoded.isUpgraded == "true")
    }
}
