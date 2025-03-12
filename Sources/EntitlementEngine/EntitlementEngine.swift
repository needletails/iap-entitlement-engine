//
//  EntitlementEngine.swift
//
//
//  Created by Cole M on 5/30/23.
//

import Foundation
import HTTPTypes
import APNSCore
import APNS
import NeedleTailLogger

public actor EntitlementEngine {
    
    public let currentDate = Date()
    public let storeDelegate: EntitlementStoreDelegate
    public let weeklyProductID: String
    public let monthlyProductID: String
    public let yearlyProductID: String
    public let apnTopic: String
    public let deviceToken: String
    private let logger = NeedleTailLogger(.init(label: "[IAPEntitlementEngine]"))
    private var order: Order?
    private var orderId: String = ""
    
    public init(
        storeDelegate: EntitlementStoreDelegate,
        weeklyProductID: String,
        monthlyProductID: String,
        yearlyProductID: String,
        apnTopic: String,
        deviceToken: String
    ) {
        self.storeDelegate = storeDelegate
        self.weeklyProductID = weeklyProductID
        self.monthlyProductID = monthlyProductID
        self.yearlyProductID = yearlyProductID
        self.deviceToken = deviceToken
        self.apnTopic = apnTopic
    }
    
    func isCancelled(latestReceiptInfo: LatestReceiptInfo) async -> Bool {
        var cancelled: Bool
        guard let cancellationDate = Int64(latestReceiptInfo.cancellationDateMs ?? "") else { return false }
        
        if Date(milliseconds: cancellationDate) >= currentDate {
            cancelled = true
        } else {
            cancelled = false
        }
        return cancelled
    }
    
    private func cancellationReason(latestReceiptInfo: LatestReceiptInfo) -> String {
        var reason: String
        if latestReceiptInfo.cancellationReason == CancellationInteger.cancellationIntegerZero.rawValue {
            reason = CancellationReason.reasonOne.rawValue
        } else {
            reason =  CancellationReason.reasonTwo.rawValue
        }
        return reason
    }
    
    private func isTrial(latestReceiptInfo: LatestReceiptInfo) -> Bool {
        var trial: Bool
        if latestReceiptInfo.isTrialPeriod == IsTrial.isTrue.rawValue {
            trial = true
        } else {
            trial = false
        }
        return trial
    }
    
    private func isIntroOffer(latestReceiptInfo: LatestReceiptInfo) -> Bool {
        var intro: Bool
        if latestReceiptInfo.isInIntroOfferPeriod == IsIntroOffer.isTrue.rawValue {
            intro = true
        } else {
            intro = false
        }
        return intro
    }
    
    private func isUpgraded(latestReceiptInfo: LatestReceiptInfo) -> Bool {
        var upgraded: Bool
        if latestReceiptInfo.isUpgraded == IsUpgraded.isTrue.rawValue {
            upgraded = true
        } else {
            upgraded = false
        }
        return upgraded
    }
    
    private func isAutoRenew(pendingRenewalInfo: PendingRenewalInfo) -> Bool {
        var autoRenewable: Bool
        if pendingRenewalInfo.autoRenewStatus == IsAutoRenew.one.rawValue {
            autoRenewable = true
        } else {
            autoRenewable = false
        }
        return autoRenewable
    }
    
    private func isExpired(latestReceiptInfo: LatestReceiptInfo) -> Bool {
        var expired: Bool
        guard let expirationDate = Int64(latestReceiptInfo.expiresDateMs) else {return false}
        if currentDate > Date(milliseconds: expirationDate){
            expired = true
        } else {
            expired = false
        }
        return expired
    }
    
    private func expiresToday(latestReceiptInfo: LatestReceiptInfo) -> Bool {
        var expired: Bool
        guard let expirationDate = Int64(latestReceiptInfo.expiresDateMs) else {return false}
        if Date(milliseconds: expirationDate) == currentDate {
            expired = true
        } else {
            expired = false
        }
        return expired
    }
    
    private func gracePeriodWillExpired(pendingRenewalInfo: PendingRenewalInfo) -> Bool {
        guard let expirationDate = Int64(pendingRenewalInfo.gracePeriodExpiresDateMs ?? "") else {return false}
        var expired: Bool
        let almostExpired = Calendar.current.date(byAdding: .day, value: -7, to: Date(milliseconds: expirationDate))!
        if currentDate >= almostExpired {
            expired = true
        } else {
            expired = false
        }
        return expired
    }
    
    private func gracePeriodExpired(pendingRenewalInfo: PendingRenewalInfo) -> Bool {
        var expired: Bool
        guard let expirationDate = Int64(pendingRenewalInfo.gracePeriodExpiresDateMs ?? "") else {return false}
        if Date(milliseconds: expirationDate) >= currentDate {
            expired = true
        } else {
            expired = false
        }
        return expired
    }
    
    func expirationLogic(
        apns: APNSClient<JSONDecoder, JSONEncoder>,
        pushType: PushType,
        topic: IAPTopic,
        payload: IAPPayload? = nil,
        latestReceiptInfo: LatestReceiptInfo,
        pendingRenewalInfo: PendingRenewalInfo
    ) async throws -> HTTPResponse.Status {
        if gracePeriodWillExpired(pendingRenewalInfo: pendingRenewalInfo) {
            guard let payload = payload else { throw EntitlementError.missingPayload }
            return try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
        } else if expiresToday(latestReceiptInfo: latestReceiptInfo) {
            guard let payload = payload else { throw EntitlementError.missingPayload }
            return try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
        } else if isExpired(latestReceiptInfo: latestReceiptInfo) {
            guard let id = UUID(uuidString: orderId) else { throw EntitlementError.notFound }
            
            order?.isSubscribed = false
            guard let order = order else { throw EntitlementError.orderNotFound }
            try await storeDelegate.updateOrder(new: order, id: id)
            return .ok
        }
        return .ok
    }
    
    func cancellationLogic(
        apns: APNSClient<JSONDecoder, JSONEncoder>,
        pushType: PushType,
        topic: IAPTopic,
        payload: IAPPayload,
        latestReceiptInfo: LatestReceiptInfo
    ) async throws -> HTTPResponse.Status {
        return try await doPush(
            apns: apns,
            pushType: pushType,
            topic: topic,
            payload: payload)
    }
    
    enum PushType: Sendable {
        case alert
    }
    
    private func doPush(
        apns: sending APNSClient<JSONDecoder, JSONEncoder>,
        pushType: PushType,
        topic: IAPTopic,
        payload: IAPPayload
    ) async throws -> HTTPResponse.Status {
        switch pushType {
        case .alert:
            //TODO: Launch Image
            let alert = APNSAlertNotification(
                alert: .init(
                    title: .raw(payload.title),
                    subtitle: .raw(payload.subtitle),
                    body: .raw(payload.body),
                    launchImage: ""),
                expiration: .timeIntervalSince1970InSeconds(86400),
                priority: .immediately,
                topic: topic.topic,
                payload: payload,
                badge: 0,
                sound: .default
            )
            
            try await apns.sendAlertNotification(alert, deviceToken: deviceToken)
            return .ok
        }
    }
    
    private func turnAutoRenewOn(_
                                             apns: APNSClient<JSONDecoder, JSONEncoder>,
                                             pushType: PushType,
                                             topic: IAPTopic,
                                             payload: IAPPayload
    ) async throws -> HTTPResponse.Status {
        try await doPush(
            apns: apns,
            pushType: pushType,
            topic: topic,
            payload: payload)
    }
    
    private func sendUpgradeThankYou(
        apns: APNSClient<JSONDecoder, JSONEncoder>,
        pushType: PushType,
        topic: IAPTopic,
        payload: IAPPayload
    ) async throws -> HTTPResponse.Status {
        try await doPush(
            apns: apns,
            pushType: pushType,
            topic: topic,
            payload: payload)
    }
    
    
    private func handleTrialSubscriptionStatus(
        apns: APNSClient<JSONDecoder, JSONEncoder>,
        pushType: PushType,
        topic: IAPTopic,
        payload: IAPPayload,
        latestReceiptInfo: LatestReceiptInfo
    ) async throws -> HTTPResponse.Status {
        guard let id = UUID(uuidString: orderId) else { throw EntitlementError.notFound }
        if latestReceiptInfo.isInIntroOfferPeriod == "true" {
            let response = try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
            order?.isSubscribed = true
            guard let order = order else { throw EntitlementError.orderNotFound }
            try await storeDelegate.updateOrder(new: order, id: id)
            return response
            
        } else if latestReceiptInfo.isInIntroOfferPeriod == "false" {
            let response = try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
            order?.isSubscribed = false
            guard let order = order else { throw EntitlementError.orderNotFound }
            try await storeDelegate.updateOrder(new: order, id: id)
            return response
            
        } else if latestReceiptInfo.isTrialPeriod == "true" {
            let response = try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
            order?.isSubscribed = true
            guard let order = order else { throw EntitlementError.orderNotFound }
            try await storeDelegate.updateOrder(new: order, id: id)
            return response
            
        } else if latestReceiptInfo.isTrialPeriod == "false" {
            let response = try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
            order?.isSubscribed = false
            guard let order = order else { throw EntitlementError.orderNotFound }
            try await storeDelegate.updateOrder(new: order, id: id)
            return response
            
        }
        return .ok
    }
    
    private func handleUsersSubscriptionStatus(
        apns: sending APNSClient<JSONDecoder, JSONEncoder>,
        pushType: PushType,
        topic: IAPTopic,
        payload: IAPPayload,
        latestReceiptInfo: LatestReceiptInfo
    ) async throws -> HTTPResponse.Status {
        //We can send a notification for thanking users after upgrade or downgrade
        guard let id = UUID(uuidString: orderId) else { throw EntitlementError.notFound }
        switch latestReceiptInfo.productId {
        case weeklyProductID:
            logger.log(level: .debug, message: "Our product id: \(latestReceiptInfo.productId)")
            let response = try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
            order?.productName = latestReceiptInfo.productId
            guard let order = order else { throw EntitlementError.orderNotFound }
            try await storeDelegate.updateOrder(new: order, id: id)
            return response
            
        case monthlyProductID:
            logger.log(level: .debug, message: "Our product id: \(latestReceiptInfo.productId)")
            return try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
        case yearlyProductID:
            logger.log(level: .debug, message: "Our product id: \(latestReceiptInfo.productId)")
            let response = try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
            order?.productName = latestReceiptInfo.productId
            guard let order = order else { throw EntitlementError.orderNotFound }
            try await storeDelegate.updateOrder(new: order, id: id)
            return response
            
        default:
            logger.log(level: .debug, message: "Missing product id, we have not subscribed")
            let response = try await doPush(
                apns: apns,
                pushType: pushType,
                topic: topic,
                payload: payload)
            
            order?.productName = latestReceiptInfo.productId
            guard let order = order else { throw EntitlementError.orderNotFound }
            try await storeDelegate.updateOrder(new: order, id: id)
            return response
            
        }
    }
    
    //Here is our entitlement engine that sends our user notification along with their user status
    public func processReceipt(
        apns: sending APNSClient<JSONDecoder, JSONEncoder>,
        order: Order,
        orderId: String,
        latestReceiptInfo: LatestReceiptInfo,
        pendingRenewalInfo: PendingRenewalInfo
    ) async throws -> HTTPResponse.Status {
        self.order = order
        self.orderId = orderId
        if !latestReceiptInfo.productId.isEmpty {
            do {
                if gracePeriodWillExpired(pendingRenewalInfo: pendingRenewalInfo) {
                    
                    guard let expirationDate = Int64(latestReceiptInfo.expiresDateMs) else { throw EntitlementError.notFound }
                    let df = DateFormatter()
                    let expire = df.getFormattedDate(currentFormat: DateFormats.eighth.rawValue, newFormat: DateFormats.sixth.rawValue, date: Date(milliseconds: expirationDate))
                    
                    let payload = IAPPayload(
                        title: APNMessages.autoRenewOff.rawValue,
                        subtitle: "\(APNMessages.turnOnAutoRenew.rawValue) \(expire).",
                        body: APNMessages.turnAutoOnBody.rawValue
                    )
                    
                    return try await turnAutoRenewOn(
                        apns,
                        pushType: .alert,
                        topic: .init(topic: self.apnTopic),
                        payload: payload)
                    
                } else if expiresToday(latestReceiptInfo: latestReceiptInfo) {
                    
                    guard let expirationDate = Int64(latestReceiptInfo.expiresDateMs) else { throw EntitlementError.notFound }
                    let df = DateFormatter()
                    let expire = df.getFormattedDate(currentFormat: DateFormats.eighth.rawValue, newFormat: DateFormats.sixth.rawValue, date: Date(milliseconds: expirationDate))
                    
                    let payload = IAPPayload(
                        title: APNMessages.subscriptionStatus.rawValue,
                        subtitle: "\(APNMessages.expiresTodaySubtitle.rawValue) \(expire).",
                        body: APNMessages.expiresTodayBody.rawValue
                    )
                    
                    return try await expirationLogic(
                        apns: apns,
                        pushType: .alert,
                        topic: .init(topic: self.apnTopic),
                        payload: payload,
                        latestReceiptInfo: latestReceiptInfo,
                        pendingRenewalInfo: pendingRenewalInfo)
                    
                } else if isExpired(latestReceiptInfo: latestReceiptInfo) {
                    
                    return try await expirationLogic(
                        apns: apns,
                        pushType: .alert,
                        topic: .init(topic: self.apnTopic),
                        latestReceiptInfo: latestReceiptInfo,
                        pendingRenewalInfo: pendingRenewalInfo)
                    
                } else if await isCancelled(latestReceiptInfo: latestReceiptInfo) {
                    
                    var payload: IAPPayload
                    switch latestReceiptInfo.productId {
                    case weeklyProductID:
                        payload = IAPPayload(
                            title: APNMessages.subscriptionStatus.rawValue,
                            subtitle: APNMessages.weeklyProductSubtitle.rawValue,
                            body: APNMessages.weeklyProductBody.rawValue
                        )
                    case monthlyProductID:
                        payload = IAPPayload(
                            title: APNMessages.subscriptionStatus.rawValue,
                            subtitle: APNMessages.monthlyProductSubtitle.rawValue,
                            body: APNMessages.monthlyProductBody.rawValue
                        )
                    case yearlyProductID:
                        payload = IAPPayload(
                            title: APNMessages.subscriptionStatus.rawValue,
                            subtitle: APNMessages.yearlyProductSubtitle.rawValue,
                            body: APNMessages.yearlyProductBody.rawValue
                        )
                    default:
                        payload = IAPPayload(
                            title: APNMessages.notSubscribed.rawValue,
                            subtitle: APNMessages.notSubscribedSubtitle.rawValue,
                            body: APNMessages.notSubscribedBody.rawValue
                        )
                    }
                    
                    return try await handleUsersSubscriptionStatus(
                        apns: apns,
                        pushType: .alert,
                        topic: .init(topic: self.apnTopic),
                        payload: payload,
                        latestReceiptInfo: latestReceiptInfo)
                    
                } else if isUpgraded(latestReceiptInfo: latestReceiptInfo) {
                    
                    let payload = IAPPayload(
                        title: APNMessages.thankYouSubscribe.rawValue,
                        subtitle: APNMessages.upgradeSubtitle.rawValue,
                        body: ""
                    )
                    
                    return try await sendUpgradeThankYou(
                        apns: apns,
                        pushType: .alert,
                        topic: .init(topic: self.apnTopic),
                        payload: payload)
                    
                } else if !cancellationReason(latestReceiptInfo: latestReceiptInfo).isEmpty {
                    
                    var payload: IAPPayload
                    
                    if cancellationReason(latestReceiptInfo: latestReceiptInfo) == CancellationReason.reasonOne.rawValue {
                        payload = IAPPayload(
                            title: APNMessages.cancelled.rawValue,
                            subtitle: APNMessages.cancelledSubtitle.rawValue,
                            body: APNMessages.cancelledBody.rawValue
                        )
                    } else {
                        //User Is Refunded because of a potential issue in the app set the User Subscription State accordingly and message the user appologizing and asking for feed back
                        payload = IAPPayload(
                            title: APNMessages.cancelled.rawValue,
                            subtitle: APNMessages.cancelledSubtitle.rawValue,
                            body: APNMessages.cancelledIssueBody.rawValue
                        )
                    }
                    
                    return try await cancellationLogic(
                        apns: apns,
                        pushType: .alert,
                        topic: .init(topic: self.apnTopic),
                        payload: payload,
                        latestReceiptInfo: latestReceiptInfo)
                    
                } else if isTrial(latestReceiptInfo: latestReceiptInfo) {
                    
                    return try await handleTrialSubscriptionStatus(
                        apns: apns,
                        pushType: .alert,
                        topic: .init(topic: self.apnTopic),
                        payload: getPayload(latestReceiptInfo: latestReceiptInfo),
                        latestReceiptInfo: latestReceiptInfo)
                    
                } else if isIntroOffer(latestReceiptInfo: latestReceiptInfo) {
                    
                    return try await handleTrialSubscriptionStatus(
                        apns: apns,
                        pushType: .alert,
                        topic: .init(topic: self.apnTopic),
                        payload: getPayload(latestReceiptInfo: latestReceiptInfo),
                        latestReceiptInfo: latestReceiptInfo)
                    
                }
            } catch {
                logger.log(level: .error, message: "We have an error processing the latest receipt, Error: \(error)")
            }
        } else {
            
            let payload = IAPPayload(
                title: APNMessages.notSubscribed.rawValue,
                subtitle: APNMessages.notSubscribedBody.rawValue,
                body: ""
            )
            
            return try await doPush(
                apns: apns,
                pushType: .alert,
                topic: .init(topic: self.apnTopic),
                payload: payload)
        }
        return .ok
    }
    
    private func getPayload(latestReceiptInfo: LatestReceiptInfo) -> IAPPayload {
        if latestReceiptInfo.isInIntroOfferPeriod == "true" {
            return IAPPayload(
                title: APNMessages.subscriptionStatus.rawValue,
                subtitle: APNMessages.introOfferPeriod.rawValue,
                body: APNMessages.introOfferPeriodBody.rawValue
            )
        } else if latestReceiptInfo.isInIntroOfferPeriod == "false" {
            return IAPPayload(
                title: APNMessages.subscriptionStatus.rawValue,
                subtitle: APNMessages.introOfferExpired.rawValue,
                body: APNMessages.introOfferExpiredBody.rawValue
            )
        } else if latestReceiptInfo.isTrialPeriod == "true" {
            return IAPPayload(
                title: APNMessages.subscriptionStatus.rawValue,
                subtitle: APNMessages.trialPeriod.rawValue,
                body: APNMessages.trialPeriodBody.rawValue
            )
        } else if latestReceiptInfo.isTrialPeriod == "false" {
            return IAPPayload(
                title: APNMessages.subscriptionStatus.rawValue,
                subtitle: APNMessages.trialPeriodExpired.rawValue,
                body: APNMessages.trialPeriodExpiredBody.rawValue
            )
        } else {
            fatalError("This should never happen")
        }
    }
}

private enum EntitlementError: Error, Sendable {
    case notFound, missingPayload, orderNotFound
}

extension APNSResponse: @retroactive @unchecked Sendable {}
