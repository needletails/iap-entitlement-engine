import Foundation
import Testing
@testable import IAPEntitlementEngine

/// a revocation date on a transaction that is not the subscription's current period.
@Suite("Refund of an earlier period")
struct EarlierPeriodRefundTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()

    var engine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
    }

    func process(_ order: Order, _ transaction: AppStoreTransaction, _ renewal: AppStoreRenewalInfo) async throws {
        _ = try await engine.processAppStoreTransaction(
            notifier: notifier, order: order,
            transaction: transaction, renewalInfo: renewal)
    }

    let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)
    let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
    let aMinuteAgo = now.addingTimeInterval(-60)
    let inTwentyDays = now.addingTimeInterval(20 * 86_400)

    /// Last month's renewal, refunded a minute ago. Its period ended ten days ago.
    var refundedEarlierPeriod: AppStoreTransaction {
        AppStoreTransaction(
            productId: "monthly", originalTransactionId: "1", expiresDate: tenDaysAgo,
            revocationDate: aMinuteAgo, revocationReason: 0)
    }

    // MARK: What the fix has to do

    /// The renewal info that comes with the REFUND notification describes the subscription as
    /// it is now: renewing, and paid until twenty days from now.
    @Test func refundOfAnEarlierPeriodLeavesTheCurrentOneAlone() async throws {
        try await process(
            subscriber, refundedEarlierPeriod,
            AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, isInBillingRetryPeriod: false,
                renewalDate: inTwentyDays))
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    // MARK: Real ends still end

    @Test func refundOfTheCurrentPeriodEndsAccess() async throws {
        try await process(
            subscriber,
            AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: inTwentyDays,
                revocationDate: aMinuteAgo, revocationReason: 0),
            AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 0, renewalDate: inTwentyDays))
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.map(\.collapseID) == ["cancelled"])
    }

    /// The last event Apple sends. The subscription lapsed ten days ago, the expiry was missed
    /// or read by a clock that ran behind, so the order still says subscribed. The customer then
    /// gets that last period refunded. Nothing else will ever arrive for this subscription.
    @Test func refundOfTheLastPeriodAfterItLapsedStillEndsAccess() async throws {
        try await process(
            subscriber, refundedEarlierPeriod,
            AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 0, isInBillingRetryPeriod: false,
                renewalDate: tenDaysAgo))
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    /// The same last event when the caller passes renewal info without a renewal date.
    @Test func refundAfterALapseEndsAccessWhenAppleDoesNotSayWhichPurchaseIsLatest() async throws {
        try await process(
            subscriber, refundedEarlierPeriod,
            AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 0, isInBillingRetryPeriod: false))
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    @Test func refundWithNoRenewalInfoEndsAccess() async throws {
        try await process(subscriber, refundedEarlierPeriod, AppStoreRenewalInfo())
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    /// A refund granted during its own period, processed after that period ended.
    @Test func lateNewsOfARefundGrantedDuringItsPeriodEndsAccess() async throws {
        try await process(
            subscriber,
            AppStoreTransaction(
                productId: "monthly", originalTransactionId: "1", expiresDate: aMinuteAgo,
                revocationDate: tenDaysAgo, revocationReason: 0),
            AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 0, renewalDate: aMinuteAgo))
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    @Test func revocationWithNoExpiryDateEndsAccess() async throws {
        try await process(
            subscriber,
            AppStoreTransaction(productId: "monthly", originalTransactionId: "1", revocationDate: aMinuteAgo),
            AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 1, renewalDate: inTwentyDays))
        #expect(store.updates.first?.order.isSubscribed == false)
    }

    // MARK: Never grants

    @Test func refundOfAnEarlierPeriodNeverStartsASubscription() async throws {
        try await process(
            Order(id: orderID, productName: "monthly", isSubscribed: false), refundedEarlierPeriod,
            AppStoreRenewalInfo(originalTransactionId: "1", autoRenewStatus: 1, renewalDate: inTwentyDays))
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    // MARK: The same root cause without a revocation date, which no R2 rule reaches

    /// REFUND_DECLINED and CONSUMPTION_REQUEST also carry the transaction the customer asked
    /// about. When that is an earlier period it has no revocation date, and reads as an expiry.
    @Test func declinedRefundOfAnEarlierPeriodLeavesTheCurrentOneAlone() async throws {
        try await process(
            subscriber,
            AppStoreTransaction(productId: "monthly", originalTransactionId: "1", expiresDate: tenDaysAgo),
            AppStoreRenewalInfo(
                originalTransactionId: "1", autoRenewStatus: 1, isInBillingRetryPeriod: false,
                renewalDate: inTwentyDays))
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }
}
