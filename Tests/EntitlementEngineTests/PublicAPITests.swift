import APNSCore
import Foundation
import IAPEntitlementEngine
import Testing

/// Uses a plain import, so this file only compiles while the API below stays public. Every other
/// test file uses `@testable import`, which would not notice a lost `public`.
@Suite("Public API")
struct PublicAPITests {
    private struct Store: EntitlementStoreDelegate {
        func updateOrder(_ order: Order, replacing previous: Order) async throws {}
    }

    private struct Quiet: EntitlementNotifier {
        func send(_ payload: IAPPayload, for notification: EntitlementNotification, expiresAt: Date) async throws {
            _ = notification.collapseID
        }
    }

    @Test func aCallerCanUseEverythingTheReadmeDescribes() async throws {
        let engine = EntitlementEngine(
            storeDelegate: Store(), weeklyProductID: "", monthlyProductID: "monthly", yearlyProductID: "yearly",
            retiredProductIDs: ["monthly.old"], messages: .default)
        let result = try await engine.processAppStoreTransaction(
            notifier: Quiet(), order: Order(id: UUID()),
            transaction: AppStoreTransaction(productId: "monthly", expiresDate: Date().addingTimeInterval(3_600)),
            renewalInfo: AppStoreRenewalInfo(autoRenewStatus: 1, renewalDate: Date().addingTimeInterval(3_600)))
        #expect(result.didSave)
        #expect(result.order.isSubscribed == true)
        #expect(result.accessExpiresAt != nil)
        #expect(result.pushFailure == nil)
        let due = try #require(result.notification)
        #expect(EntitlementMessages.default.payload(for: due).title.isEmpty == false)

        let double = EntitlementResult(order: result.order)
        #expect(!double.didSave)
        #expect(double.accessExpiresAt == nil)
        #expect(double.notification == nil)
        #expect(double.pushFailure == nil)
    }

    @Test func aCallerCanTellPushFailuresApart() {
        func describe(_ failure: any Error) -> String {
            switch failure {
            case let error as APNSError: "apns \(error.responseStatus)"
            case FCMError.unregistered: "forget the token"
            case FCMError.requestFailed(let status, let code, let retryAfter, _): "fcm \(status) \(code ?? "") \(retryAfter ?? 0)"
            case PushTransportError.timeout: "retry"
            case PushTransportError.connection(let description): description
            case PushTransportError.invalidRequest: "do not retry"
            default: "log it"
            }
        }
        #expect(describe(FCMError.unregistered) == "forget the token")
        #expect(describe(PushTransportError.timeout) == "retry")
        #expect(describe(EntitlementError.missingProductID) == "log it")
    }

    @Test func theIncludedNotifiersTakeWhatACallerHolds() {
        struct Tokens: FCMAccessTokenProvider {
            func accessToken() async throws -> String { "t" }
        }
        struct Transport: FCMTransport {
            func post(url: String, headers: [String: String], body: Data) async throws -> FCMTransportResponse {
                FCMTransportResponse(status: 200, headers: [:], body: Data())
            }
        }
        _ = FCMEntitlementNotifier(
            projectID: "p", registrationToken: "r", accessTokenProvider: Tokens(), transport: Transport())
        _ = HTTPConnectionFCMTransport(timeout: .seconds(5))
        _ = GooglePlaySubscriptionPurchase(subscriptionState: "SUBSCRIPTION_STATE_ACTIVE").needsAcknowledgement
        #expect(LatestReceiptInfo() == LatestReceiptInfo())
        #expect(PendingRenewalInfo() == PendingRenewalInfo())
    }
}
