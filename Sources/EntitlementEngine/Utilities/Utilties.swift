//
//  Utilities.swift
//
//
//  Created by Cole M on 5/30/23.
//

import Foundation

enum CancellationReason: String, Sendable {
    case reasonOne = "Cancelled for some reason, perhaps the purchase was an accident"
    case reasonTwo = "Cancelled because there was an issue or a perceived issue within your app"
}

enum CancellationInteger: String, Sendable {
    case cancellationIntegerZero = "0"
    case cancellationIntegerOne = "1"
}

enum IsTrial: String, Sendable {
    case isTrue = "true"
    case isFalse = "false"
}

enum IsIntroOffer: String, Sendable {
    case isTrue = "true"
    case isFalse = "false"
}

enum IsUpgraded: String, Sendable {
    case isTrue = "true"
    case isFalse = "false"
}

enum IsAutoRenew: String, Sendable {
    case zero = "0"
    case one = "1"
}

enum APNMessages: String, Sendable {
    case thankYouSubscribe = "Thank you for subscribing"
    case expiresOn = "Your subscription will expire on:"
    case turnOnAutoRenew = "Please turn on auto renew for an uninterrupted experience!"
    case cancelled = "Cancelled Subscription"
    case cancelledSubtitle = "We are Sorry to See you go!"
    case cancelledBody = "Please feel free to subscribe at anytime!"
    case cancelledIssueBody = "We are really sorry to see you go if you experienced technical difficulties, lease let us know how we can improve."
    case autoRenewOff = "Hey Auto Renew is Off"
    case turnAutoOnBody = "If you turn auto renew on you will enjoy uninterrupted experience, also If you upgrade you can save anywhere from $30 - $150 USD/year if you upgrade to an annual subscription. What a deal!"
    case upgradeSubtitle = "Congratulations! You just save a bunch of money upgrading your Subscription"
    case subscriptionStatus = "Subscription Satutus:"
    case weeklyProductSubtitle = "Weekly Subscription"
    case weeklyProductBody = "You have weekly subscription privileges"
    case monthlyProductSubtitle = "Monthly Subscription"
    case monthlyProductBody = "You have monthly subscription privileges"
    case yearlyProductSubtitle = "Yearly Subscription"
    case yearlyProductBody = "You have yearly subscription privileges, please enjoy."
    case notSubscribed = "No Subscription"
    case notSubscribedSubtitle = "Hey, thanks for subscribing"
    case notSubscribedBody = "Enjoy the ultimate experience by subscribing"
    case expiresTodaySubtitle = "Your Subscription Will Expire Today"
    case expiresTodayBody = "Please turn on auto renew and make sure your payment method is valid in order to enjoy an uninterrupted experience."
    case introOfferPeriod = "Introductory Offer:"
    case introOfferPeriodBody = "Thank you for taking advatage of our intro offer!"
    case introOfferExpired = "Introductory Offer Expired:"
    case introOfferExpiredBody = "Thank you for taking advatage of our intro offer, in order to continue please subscribe."
    case trialPeriod = "Trial Period:"
    case trialPeriodBody = "Thank you for trying before your subscribe!"
    case trialPeriodExpired = "Trial Period Expired:"
    case trialPeriodExpiredBody = "Thank you for trying before your subscribe, in order to continue using Cartisim please subscribe."
}
