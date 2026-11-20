import Foundation
import Testing
@testable import IAPEntitlementEngine

/// What a process call hands back. A throw means nothing was saved, so everything that happens
/// after the save has to be readable here.
@Suite("Process result")
struct EntitlementResultTests {
    let store = RecordingStore()
    let notifier = RecordingNotifier()
    let expiry = now.addingTimeInterval(86_400 * 30)
    let renewing = AppStoreRenewalInfo(autoRenewStatus: 1)
    let subscriber = Order(id: orderID, productName: "monthly", isSubscribed: true)

    var active: AppStoreTransaction { AppStoreTransaction(productId: "monthly", expiresDate: expiry) }

    var engine: EntitlementEngine {
        EntitlementEngine(
            storeDelegate: store, weeklyProductID: "weekly", monthlyProductID: "monthly",
            yearlyProductID: "yearly", now: { now })
    }

    @Test func newSubscriberComesBackSavedWithTheirExpiry() async throws {
        let result = try await engine.processAppStoreTransaction(
            notifier: notifier, order: Order(id: orderID), transaction: active, renewalInfo: renewing)
        #expect(result.didSave)
        #expect(result.order.isSubscribed == true)
        #expect(result.order.productName == "monthly")
        #expect(result.order.updatedAt == now)
        #expect(result.accessExpiresAt == expiry)
        #expect(result.notification == .monthlyActive)
        #expect(result.pushFailure == nil)
    }

    @Test func renewalThatChangesNothingIsNotSavedButStillGivesTheExpiry() async throws {
        let result = try await engine.processAppStoreTransaction(
            notifier: notifier, order: subscriber, transaction: active, renewalInfo: renewing)
        #expect(!result.didSave)
        #expect(result.order == subscriber)
        #expect(result.accessExpiresAt == expiry)
        #expect(result.notification == nil)
        #expect(store.updates.isEmpty)
    }

    /// The order it replaces lets the store refuse a write that raced with another one.
    @Test func delegateReceivesTheOrderBeingReplaced() async throws {
        let before = Order(id: orderID, productName: "", isSubscribed: false)
        let result = try await engine.processAppStoreTransaction(
            notifier: notifier, order: before, transaction: active, renewalInfo: renewing)
        #expect(store.updates.count == 1)
        #expect(store.updates.first?.previous == before)
        #expect(store.updates.first?.order == result.order)
    }

    @Test func gracePeriodGivesTheEndOfTheGracePeriod() async throws {
        let grace = now.addingTimeInterval(86_400 * 3)
        let result = try await engine.processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(-60)),
            renewalInfo: AppStoreRenewalInfo(autoRenewStatus: 1, gracePeriodExpiresDate: grace))
        #expect(result.order.isSubscribed == true)
        #expect(result.accessExpiresAt == grace)
        #expect(result.notification == .billingIssue)
    }

    @Test func endedAccessHasNoExpiry() async throws {
        let result = try await engine.processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(
                productId: "monthly", expiresDate: expiry, revocationDate: now.addingTimeInterval(-60)),
            renewalInfo: renewing)
        #expect(result.didSave)
        #expect(result.order.isSubscribed == false)
        #expect(result.accessExpiresAt == nil)
        #expect(result.notification == .cancelled)
    }

    /// An event the engine leaves alone must not look like a statement about access.
    @Test func eventForAnotherProductReportsNothing() async throws {
        let result = try await engine.processAppStoreTransaction(
            notifier: notifier, order: subscriber,
            transaction: AppStoreTransaction(productId: "coins.100", expiresDate: expiry), renewalInfo: renewing)
        #expect(!result.didSave)
        #expect(result.order == subscriber)
        #expect(result.accessExpiresAt == nil)
        #expect(result.notification == nil)
    }

    @Test func failedSaveThrowsAndNothingIsPushed() async {
        let failing = EntitlementEngine(
            storeDelegate: RecordingStore(failure: TestFailure.boom), weeklyProductID: "weekly",
            monthlyProductID: "monthly", yearlyProductID: "yearly", now: { now })
        await #expect(throws: TestFailure.boom) {
            _ = try await failing.processAppStoreTransaction(
                notifier: notifier, order: Order(id: orderID), transaction: active, renewalInfo: renewing)
        }
        #expect(notifier.sent.isEmpty)
    }

    /// A dead device token must not turn an applied event into a store retry.
    @Test func failedPushOnAnUnchangedOrderIsReportedWithoutThrowing() async throws {
        let failing = RecordingNotifier(failure: FCMError.unregistered)
        let grace = now.addingTimeInterval(86_400)
        let result = try await engine.processAppStoreTransaction(
            notifier: failing, order: subscriber,
            transaction: AppStoreTransaction(productId: "monthly", expiresDate: now.addingTimeInterval(-60)),
            renewalInfo: AppStoreRenewalInfo(autoRenewStatus: 1, gracePeriodExpiresDate: grace))
        #expect(!result.didSave)
        #expect(result.notification == .billingIssue)
        #expect(result.pushFailure as? FCMError == .unregistered)
    }

    @Test func googlePurchaseGivesTheSameResult() async throws {
        let json = #"""
        {"subscriptionState":"SUBSCRIPTION_STATE_ACTIVE","lineItems":[
          {"productId":"monthly","expiryTime":"2027-02-14T08:00:00Z","autoRenewingPlan":{"autoRenewEnabled":true}}]}
        """#
        let purchase = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: Data(json.utf8))
        let result = try await engine.processGooglePlayPurchase(
            notifier: notifier, order: Order(id: orderID), purchase: purchase)
        #expect(result.didSave)
        #expect(result.order.isSubscribed == true)
        #expect(result.accessExpiresAt == expiry)
        #expect(result.notification == .monthlyActive)
    }

    @Test func receiptGivesTheSameResult() async throws {
        let result = try await engine.processReceipt(
            notifier: notifier, order: Order(id: orderID),
            latestReceiptInfo: LatestReceiptInfo(productId: "monthly", expiresDateMs: milliseconds(expiry)),
            pendingRenewalInfo: PendingRenewalInfo(autoRenewStatus: "1"))
        #expect(result.didSave)
        #expect(result.accessExpiresAt == expiry)
        #expect(result.notification == .monthlyActive)
    }
}

@Suite("Notifications")
struct EntitlementNotificationTests {
    /// Devices and custom notifiers key on these, so they are part of the API.
    @Test func collapseIDsAreTheStableRawValues() {
        #expect(Set(EntitlementNotification.allCases.map(\.collapseID)).count == EntitlementNotification.allCases.count)
        for notification in EntitlementNotification.allCases {
            #expect(notification.collapseID == notification.rawValue)
        }
        #expect(EntitlementNotification.billingIssue.collapseID == "billing-issue")
    }
}

@Suite("Stored order")
struct StoredOrderTests {
    /// Callers persist orders, so a renamed key would silently empty a field of every saved row.
    @Test func encodedFormIsFixed() throws {
        let order = Order(
            id: orderID, productName: "monthly", imageString: "i", currency: "USD", quantity: 1, price: 999,
            isPurchased: true, isSubscribed: true, orderDescription: "d",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            deletedAt: Date(timeIntervalSince1970: 3))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = String(decoding: try encoder.encode(order), as: UTF8.self)
        let expected = #"{"createdAt":1,"currency":"USD","deletedAt":3,"id":"11111111-2222-3333-4444-555555555555","imageString":"i","isPurchased":true,"isSubscribed":true,"orderDescription":"d","price":999,"productName":"monthly","quantity":1,"updatedAt":2}"#
        #expect(json == expected)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(Order.self, from: Data(expected.utf8)) == order)
    }
}
