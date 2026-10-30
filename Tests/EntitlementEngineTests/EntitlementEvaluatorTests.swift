import Foundation
import Testing
@testable import IAPEntitlementEngine

@Suite("Platform-neutral entitlement rules")
struct EntitlementEvaluatorTests {
    let evaluator = EntitlementEvaluator(catalog: catalog)

    func snapshot(
        _ lifecycle: SubscriptionSnapshot.Lifecycle,
        product: String = "monthly",
        expiresIn: TimeInterval? = 30 * 86_400,
        autoRenew: Bool = true,
        offer: SubscriptionSnapshot.Offer = .none
    ) -> SubscriptionSnapshot {
        SubscriptionSnapshot(
            productID: product,
            lifecycle: lifecycle,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) },
            autoRenewEnabled: autoRenew,
            offer: offer)
    }

    func order(subscribed: Bool, product: String? = "monthly") -> Order {
        Order(id: orderID, productName: product, isSubscribed: subscribed)
    }

    // MARK: Active

    @Test func renewedPaidSubscriberStaysEntitledWithoutAPush() {
        let decision = evaluator.evaluate(snapshot(.active), order: order(subscribed: true), now: now)
        #expect(decision == .init(isSubscribed: true, productName: "monthly", notification: nil))
    }

    @Test func expiryInThePastIsNeverEntitled() {
        let decision = evaluator.evaluate(snapshot(.active, expiresIn: -1), order: order(subscribed: true), now: now)
        #expect(decision.isSubscribed == false)
        #expect(decision.notification == nil)
    }

    @Test func expiryExactlyNowIsNotEntitled() {
        let decision = evaluator.evaluate(snapshot(.active, expiresIn: 0), order: order(subscribed: true), now: now)
        #expect(decision.isSubscribed == false)
    }

    @Test func missingExpiryIsNeverEntitled() {
        let decision = evaluator.evaluate(snapshot(.active, expiresIn: nil), order: order(subscribed: true), now: now)
        #expect(decision.isSubscribed == false)
    }

    @Test(arguments: [
        ("weekly", EntitlementNotification.weeklyActive),
        ("monthly", .monthlyActive),
        ("yearly", .yearlyActive),
    ])
    func newSubscriberGetsTheirProductMessage(product: String, expected: EntitlementNotification) {
        let decision = evaluator.evaluate(
            snapshot(.active, product: product), order: order(subscribed: false, product: nil), now: now)
        #expect(decision == .init(isSubscribed: true, productName: product, notification: expected))
    }

    @Test func productChangeUpdatesTheOrderAndNotifies() {
        let decision = evaluator.evaluate(
            snapshot(.active, product: "yearly"), order: order(subscribed: true, product: "monthly"), now: now)
        #expect(decision == .init(isSubscribed: true, productName: "yearly", notification: .yearlyActive))
    }

    @Test func trialStartNotifiesOnceAndGrantsAccess() {
        let started = evaluator.evaluate(
            snapshot(.active, offer: .trial), order: order(subscribed: false), now: now)
        #expect(started == .init(isSubscribed: true, productName: "monthly", notification: .trialStarted))

        let repeated = evaluator.evaluate(
            snapshot(.active, offer: .trial), order: order(subscribed: true), now: now)
        #expect(repeated.isSubscribed == true)
        #expect(repeated.notification == nil)
    }

    @Test func introOfferStartNotifiesAndGrantsAccess() {
        let decision = evaluator.evaluate(
            snapshot(.active, offer: .introductory), order: order(subscribed: false), now: now)
        #expect(decision == .init(isSubscribed: true, productName: "monthly", notification: .introOfferStarted))
    }

    @Test func expiringTodayWithAutoRenewOffWarns() {
        let decision = evaluator.evaluate(
            snapshot(.active, expiresIn: 3_600, autoRenew: false), order: order(subscribed: true), now: now)
        #expect(decision.isSubscribed == true)
        #expect(decision.notification == .expiringToday)
    }

    @Test func expiringTodayWithAutoRenewOnStaysQuiet() {
        let decision = evaluator.evaluate(
            snapshot(.active, expiresIn: 3_600, autoRenew: true), order: order(subscribed: true), now: now)
        #expect(decision.notification == nil)
    }

    @Test func expiringLaterWithAutoRenewOffStaysQuiet() {
        let decision = evaluator.evaluate(
            snapshot(.active, expiresIn: 86_401, autoRenew: false), order: order(subscribed: true), now: now)
        #expect(decision.notification == nil)
    }

    @Test func nilSubscribedFlagCountsAsNotSubscribed() {
        var existing = order(subscribed: false, product: nil)
        existing.isSubscribed = nil
        let decision = evaluator.evaluate(snapshot(.active), order: existing, now: now)
        #expect(decision.notification == .monthlyActive)
    }

    // MARK: Grace and suspension

    @Test func gracePeriodKeepsAccessAndAsksForPayment() {
        let decision = evaluator.evaluate(snapshot(.gracePeriod), order: order(subscribed: true), now: now)
        #expect(decision == .init(isSubscribed: true, productName: "monthly", notification: .billingIssue))
    }

    @Test func lapsedGracePeriodRevokesAccessQuietly() {
        let decision = evaluator.evaluate(
            snapshot(.gracePeriod, expiresIn: -1), order: order(subscribed: true), now: now)
        #expect(decision.isSubscribed == false)
        #expect(decision.notification == nil)
    }

    @Test func billingSuspensionBlocksAccessAndAsksForPayment() {
        let decision = evaluator.evaluate(
            snapshot(.suspended(.billing)), order: order(subscribed: true), now: now)
        #expect(decision.isSubscribed == false)
        #expect(decision.notification == .billingIssue)
    }

    @Test func pauseBlocksAccessQuietly() {
        let decision = evaluator.evaluate(
            snapshot(.suspended(.paused)), order: order(subscribed: true), now: now)
        #expect(decision.isSubscribed == false)
        #expect(decision.notification == nil)
    }

    // MARK: Revocation

    @Test func refundRevokesEvenWithTimeRemaining() {
        let decision = evaluator.evaluate(
            snapshot(.revoked(.other)), order: order(subscribed: true), now: now)
        #expect(decision.isSubscribed == false)
        #expect(decision.notification == .cancelled)
    }

    @Test func appIssueRefundUsesTheApologyMessage() {
        let decision = evaluator.evaluate(
            snapshot(.revoked(.appIssue)), order: order(subscribed: true), now: now)
        #expect(decision.notification == .cancelledAppIssue)
    }

    @Test func alreadyRevokedOrderIsNotNotifiedAgain() {
        let decision = evaluator.evaluate(
            snapshot(.revoked(.other)), order: order(subscribed: false), now: now)
        #expect(decision.notification == nil)
    }

    @Test func refundOfARetiredProductStillRevokes() {
        let decision = evaluator.evaluate(
            snapshot(.revoked(.other), product: "retired"), order: order(subscribed: true), now: now)
        #expect(decision.isSubscribed == false)
    }

    // MARK: Not subscribed

    @Test func unknownProductIsNeverEntitled() {
        let decision = evaluator.evaluate(
            snapshot(.active, product: "from-another-app"), order: order(subscribed: true), now: now)
        #expect(decision == .init(isSubscribed: false, productName: nil, notification: .notSubscribed))
    }

    @Test func lapsedSubscriberWithEmptyReceiptIsRevokedAndTold() {
        let decision = evaluator.evaluate(
            snapshot(.notSubscribed, product: ""), order: order(subscribed: true), now: now)
        #expect(decision == .init(isSubscribed: false, productName: nil, notification: .notSubscribed))
    }

    @Test func someoneWhoNeverSubscribedIsNotNagged() {
        let decision = evaluator.evaluate(
            snapshot(.notSubscribed, product: ""), order: order(subscribed: false), now: now)
        #expect(decision.notification == nil)
    }

    // MARK: No state change

    @Test func pendingLeavesTheOrderUntouched() {
        let decision = evaluator.evaluate(snapshot(.pending), order: order(subscribed: true), now: now)
        #expect(decision == .init(isSubscribed: nil, productName: nil, notification: nil))
    }

    @Test func upgradeThanksTheUserWithoutTouchingAccess() {
        let decision = evaluator.evaluate(snapshot(.upgraded), order: order(subscribed: true), now: now)
        #expect(decision == .init(isSubscribed: nil, productName: nil, notification: .upgraded))
    }
}

@Suite("Default messages")
struct EntitlementMessagesTests {
    @Test(arguments: EntitlementNotification.allCases)
    func everyNotificationHasATitle(notification: EntitlementNotification) {
        #expect(!EntitlementMessages.default.payload(for: notification).title.isEmpty)
    }

    @Test(arguments: EntitlementNotification.allCases)
    func collapseIDsFitAPNsLimit(notification: EntitlementNotification) {
        #expect(notification.collapseID.utf8.count <= 64)
    }

    @Test func noAppSpecificCopyLeaksIntoDefaults() {
        for notification in EntitlementNotification.allCases {
            let payload = EntitlementMessages.default.payload(for: notification)
            let text = "\(payload.title) \(payload.subtitle) \(payload.body)"
            #expect(!text.contains("Cartisim"))
            #expect(!text.contains("$"))
        }
    }

    @Test func messagesCanBeOverridden() {
        var messages = EntitlementMessages.default
        messages.billingIssue = IAPPayload(title: "Pago", subtitle: "", body: "")
        #expect(messages.payload(for: .billingIssue).title == "Pago")
    }
}
