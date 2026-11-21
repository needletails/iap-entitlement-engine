import Foundation
import IAPEntitlementEngine
import Testing

// The README's one-time purchase samples, against the public API only (no @testable import).
// Names the README leaves to the reader (`database`, `notificationType`) are stubbed here.

private struct ReadmeDatabase: Sendable {
    struct Connection: Sendable {
        func updatePurchase(_ record: PurchaseRecord, whereRevision: Int) async throws {}
        func insertPurchase(_ record: PurchaseRecord) async throws {}
        func addToBalance(_ change: Int, of productID: String, account: String?) async throws {}
    }
    func transaction(_ body: (Connection) async throws -> Void) async throws { try await body(Connection()) }
}

private struct ReadmePurchaseStore: PurchaseStoreDelegate {
    let database = ReadmeDatabase()

    func purchase(transactionID: String, store: PurchaseRecord.Store) async throws -> PurchaseRecord? { nil }

    func savePurchase(
        _ record: PurchaseRecord, replacing previous: PurchaseRecord?, quantityChange: Int
    ) async throws {
        try await database.transaction { db in
            if let previous {
                try await db.updatePurchase(record, whereRevision: previous.revision)
            } else {
                try await db.insertPurchase(record)
            }
            try await db.addToBalance(quantityChange, of: record.productID, account: record.accountID)
        }
    }
}

private struct ReadmeNotifier: EntitlementNotifier {
    func send(_ payload: IAPPayload, for notification: EntitlementNotification, expiresAt: Date) async throws {}
}

private enum ReadmeNotificationType { case refundReversed, other }
private struct ReadmeNotification { let signedDate: Date }

@Suite("One-time purchases: the README samples compile")
struct OneTimePurchaseReadmeTests {
    @Test func theOneTimePurchaseSamplesCompileAndRun() async throws {
        let myPurchaseStore = ReadmePurchaseStore()
        let purchases = PurchaseEngine(
            storeDelegate: myPurchaseStore,
            products: [
                OneTimeProduct(id: "com.example.coins.100", kind: .consumable),
                OneTimeProduct(id: "com.example.pro", kind: .nonConsumable),
                OneTimeProduct(id: "com.example.season", kind: .nonRenewing(duration: 90 * 86_400)),
            ]
        )
        let notifier = ReadmeNotifier()
        let transaction = AppStoreTransaction(
            productId: "com.example.coins.100", transactionId: "1", appAccountToken: "buyer")
        let notification = ReadmeNotification(signedDate: Date())
        var result: PurchaseResult
        for notificationType in [ReadmeNotificationType.other, .refundReversed] {
            switch notificationType {
            case .refundReversed:
                result = try await purchases.processAppStoreRefundReversal(
                    notifier: notifier, transaction: transaction, signedDate: notification.signedDate)
            default:
                result = try await purchases.processAppStoreTransaction(notifier: notifier, transaction: transaction)
            }
            #expect(result.outcome == .granted)
        }

        let response = Data(#"{"purchaseState":0,"consumptionState":0,"acknowledgementState":0,"orderId":"GPA.1","quantity":2,"refundableQuantity":2,"obfuscatedExternalAccountId":"buyer","purchaseTimeMillis":"1700000000000","kind":"androidpublisher#productPurchase","regionCode":"US"}"#.utf8)
        let productID = "com.example.coins.100"
        let purchaseToken = "token"
        let voided: GooglePlayProductPurchase.Voided? = nil
        let google = try await purchases.processGooglePlayPurchase(
            notifier: notifier,
            productID: productID,
            purchaseToken: purchaseToken,
            purchase: try JSONDecoder().decode(GooglePlayProductPurchase.self, from: response),
            voided: voided
        )
        #expect(google.quantityChange == 2)
        #expect(google.record?.isRevoked == false)
    }
}
