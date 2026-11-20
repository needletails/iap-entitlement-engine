import Foundation
import Testing
@testable import IAPEntitlementEngine

/// a lapsed receipt whose pending_renewal_info entry Apple has removed.
@Suite("Receipt with no renewal entry")
struct ReceiptRenewalEntryTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()

    var engine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
    }

    let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)
    let lapsed = LatestReceiptInfo(
        productId: "monthly", originalTransactionId: "1",
        expiresDateMs: milliseconds(now.addingTimeInterval(-3_600)))

    func process(_ renewal: PendingRenewalInfo) async throws {
        _ = try await engine.processReceipt(
            notifier: notifier, order: subscriber,
            latestReceiptInfo: lapsed, pendingRenewalInfo: renewal)
    }

    /// The way out that exists today: the caller states what Apple's missing entry means.
    @Test func statingThatRenewalIsOffEndsAccessQuietly() async throws {
        try await process(PendingRenewalInfo(originalTransactionId: "1", autoRenewStatus: "0"))
        #expect(store.updates.first?.order.isSubscribed == false)
        #expect(notifier.sent.isEmpty)
    }

    /// A value the caller did not fill in still changes nothing.
    @Test func anEmptyValueStillThrowsAndSavesNothing() async {
        await #expect(throws: EntitlementError.missingRenewalInfo) { try await process(PendingRenewalInfo()) }
        #expect(store.updates.isEmpty)
        #expect(notifier.sent.isEmpty)
    }

    /// What `nil means expiry` would do to the caller whose lookup found nothing while Apple's
    /// real entry says the customer is in a grace period. Passing the real entry keeps access.
    @Test func theRealEntryForTheSameReceiptKeepsAccessInAGracePeriod() async throws {
        try await process(PendingRenewalInfo(
            originalTransactionId: "1", autoRenewStatus: "1",
            gracePeriodExpiresDateMs: milliseconds(now.addingTimeInterval(3 * 86_400)), isInBillingRetryPeriod: "1"))
        #expect(!store.updates.contains { $0.order.isSubscribed == false })
        #expect(notifier.sent.map(\.collapseID) == ["billing-issue"])
    }

    /// Only the original transaction ID is not a statement about renewal, yet it ends access today.
    @Test func anEntryWithOnlyAnOriginalTransactionIDEndsAccess() async throws {
        try await process(PendingRenewalInfo(originalTransactionId: "1"))
        #expect(store.updates.first?.order.isSubscribed == false)
    }
}
