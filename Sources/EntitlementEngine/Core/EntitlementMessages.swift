//
//  EntitlementMessages.swift
//  iap-entitlement-engine
//

/// The user-facing events the engine can announce.
///
/// A later release can add cases, so end a `switch` over it with `@unknown default`.
@nonexhaustive
public enum EntitlementNotification: String, Sendable, CaseIterable {
    case upgraded
    case billingIssue = "billing-issue"
    case expiringToday = "expiring-today"
    case trialStarted = "trial-started"
    case introOfferStarted = "intro-offer-started"
    case weeklyActive = "weekly-active"
    case monthlyActive = "monthly-active"
    case yearlyActive = "yearly-active"
    case cancelled
    case cancelledAppIssue = "cancelled-app-issue"
    case notSubscribed = "not-subscribed"
    case purchased
    case purchaseRefunded = "purchase-refunded"
    case purchaseReinstated = "purchase-reinstated"

    /// Lets the device replace an earlier copy of the same message, so a repeat does not stack up.
    /// The value is the raw value, and it will not change for an existing case.
    public var collapseID: String { rawValue }
}

/// The copy for every notification. Override any of it to match your app or to localize.
public struct EntitlementMessages: Sendable, Equatable {
    public var upgraded = IAPPayload(
        title: "Thank you for upgrading",
        subtitle: "Your subscription has been upgraded.",
        body: "")
    public var billingIssue = IAPPayload(
        title: "Payment issue",
        subtitle: "We couldn't renew your subscription.",
        body: "Please update your payment method to keep your access.")
    public var expiringToday = IAPPayload(
        title: "Subscription status",
        subtitle: "Your subscription expires today.",
        body: "Turn on auto-renew to keep your access.")
    public var trialStarted = IAPPayload(
        title: "Subscription status",
        subtitle: "Your free trial has started.",
        body: "Thank you for trying us out!")
    public var introOfferStarted = IAPPayload(
        title: "Subscription status",
        subtitle: "Your introductory offer has started.",
        body: "Thank you for taking advantage of our offer!")
    public var weeklyActive = IAPPayload(
        title: "Subscription status",
        subtitle: "Weekly subscription",
        body: "You have weekly subscription privileges.")
    public var monthlyActive = IAPPayload(
        title: "Subscription status",
        subtitle: "Monthly subscription",
        body: "You have monthly subscription privileges.")
    public var yearlyActive = IAPPayload(
        title: "Subscription status",
        subtitle: "Yearly subscription",
        body: "You have yearly subscription privileges.")
    public var cancelled = IAPPayload(
        title: "Subscription cancelled",
        subtitle: "We're sorry to see you go.",
        body: "You're welcome back at any time.")
    public var cancelledAppIssue = IAPPayload(
        title: "Subscription cancelled",
        subtitle: "We're sorry to see you go.",
        body: "We're sorry for any technical difficulties. Please let us know how we can improve.")
    public var notSubscribed = IAPPayload(
        title: "No subscription",
        subtitle: "Subscribe to get the full experience.",
        body: "")

    public var purchased = IAPPayload(
        title: "Purchase complete",
        subtitle: "Thank you for your purchase.",
        body: "")
    public var purchaseRefunded = IAPPayload(
        title: "Purchase refunded",
        subtitle: "Your purchase was refunded.",
        body: "")

    public var purchaseReinstated = IAPPayload(
        title: "Purchase restored",
        subtitle: "Your purchase is yours again.",
        body: "")

    public static let `default` = EntitlementMessages()

    public init() {}

    /// The copy for one notification. Use it to resend a push that failed.
    public func payload(for notification: EntitlementNotification) -> IAPPayload {
        switch notification {
        case .upgraded: upgraded
        case .billingIssue: billingIssue
        case .expiringToday: expiringToday
        case .trialStarted: trialStarted
        case .introOfferStarted: introOfferStarted
        case .weeklyActive: weeklyActive
        case .monthlyActive: monthlyActive
        case .yearlyActive: yearlyActive
        case .cancelled: cancelled
        case .cancelledAppIssue: cancelledAppIssue
        case .notSubscribed: notSubscribed
        case .purchased: purchased
        case .purchaseRefunded: purchaseRefunded
        case .purchaseReinstated: purchaseReinstated
        }
    }
}
