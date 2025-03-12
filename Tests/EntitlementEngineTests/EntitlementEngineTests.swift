import Foundation
import Testing
import APNS
import APNSCore
import NIOPosix
@testable import IAPEntitlementEngine

final class MockEntitlementStoreDelegate: EntitlementStoreDelegate, @unchecked Sendable {
    var updatedOrder: Order?
    var updateOrderCalled = false
    
    func updateOrder(new: Order, id: UUID) async throws {
        updatedOrder = new
        updateOrderCalled = true
    }
}

class EntitlementEngineTests {
    
    var entitlementEngine: EntitlementEngine!
    var mockStoreDelegate: MockEntitlementStoreDelegate!
    
   init() {
        // Setup mock dependencies
        mockStoreDelegate = MockEntitlementStoreDelegate()
        
        // Initialize EntitlementEngine with mock dependencies
        entitlementEngine = EntitlementEngine(
            storeDelegate: mockStoreDelegate,
            weeklyProductID: "weekly",
            monthlyProductID: "monthly",
            yearlyProductID: "yearly",
            apnTopic: "topic",
            deviceToken: "deviceToken"
        )
    }
    
    @Test
    func testIsCancelled_whenCancelled() async {
        // Given
        let latestReceiptInfo = LatestReceiptInfo(cancellationDateMs: "999999999999")
        
        // When
        let result = await entitlementEngine.isCancelled(latestReceiptInfo: latestReceiptInfo)
        print(result)
        // Then
        #expect(result == true)
    }
    
    @Test
    func testIsCancelled_whenNotCancelled() async {
        // Given
        let latestReceiptInfo = LatestReceiptInfo(cancellationDateMs: "0")
        
        // When
        let result = await entitlementEngine.isCancelled(latestReceiptInfo: latestReceiptInfo)
        
        // Then
        #expect(result == false)
    }
    
    @Test
    func testExpirationLogic_whenGracePeriodWillExpire() async throws {
        // Given
        let latestReceiptInfo = LatestReceiptInfo(expiresDateMs: "1234567890000")
        let pendingRenewalInfo = PendingRenewalInfo(gracePeriodExpiresDateMs: "1234567890000")
        let order = Order(id: UUID(), isSubscribed: true)
        
        // When
        let result = try await entitlementEngine.expirationLogic(
            apns: createClient(),
            pushType: .alert,
            topic: IAPTopic(topic: "topic"),
            payload: IAPPayload(title: "Title", subtitle: "Subtitle", body: "Body"),
            latestReceiptInfo: latestReceiptInfo,
            pendingRenewalInfo: pendingRenewalInfo
        )
        // Then
        #expect(result == .ok)
    }
    
    @Test
    func testProcessReceipt_whenNotSubscribed() async throws {
        // Given
        let latestReceiptInfo = LatestReceiptInfo(productId: "")
        let pendingRenewalInfo = PendingRenewalInfo(gracePeriodExpiresDateMs: "")
        let order = Order(id: UUID(), isSubscribed: false)
        
        // When
        let result = try await entitlementEngine.processReceipt(
            apns: createClient(),
            order: order,
            orderId: "orderID",
            latestReceiptInfo: latestReceiptInfo,
            pendingRenewalInfo: pendingRenewalInfo
        )
        
        // Then
        #expect(result == .ok)
    }
    
    @Test
    func testProcessReceipt_whenSubscriptionCancelled() async throws {
        // Given
        let latestReceiptInfo = LatestReceiptInfo(productId: "weekly", cancellationDateMs: "999999999999")
        let pendingRenewalInfo = PendingRenewalInfo(gracePeriodExpiresDateMs: "")
        let order = Order(id: UUID(), isSubscribed: false)
        
        // When
        let result = try await entitlementEngine.processReceipt(
            apns: createClient(),
            order: order,
            orderId: "orderID",
            latestReceiptInfo: latestReceiptInfo,
            pendingRenewalInfo: pendingRenewalInfo
        )
        
        // Then
        #expect(result == .ok)
    }
    
    @Test
    func testCancellationLogic_whenCancelled() async throws {
        // Given
        let latestReceiptInfo = LatestReceiptInfo(cancellationDateMs: "1234567890000")
        let payload = IAPPayload(title: "Cancelled", subtitle: "Cancelled", body: "Subscription was cancelled.")
        
        // When
        let result = try await entitlementEngine.cancellationLogic(
            apns: createClient(),
            pushType: .alert,
            topic: IAPTopic(topic: "topic"),
            payload: payload,
            latestReceiptInfo: latestReceiptInfo
        )
        
        // Then
        #expect(result == .ok)
    }
    
    func createClient() -> APNSClient<JSONDecoder, JSONEncoder> {
        APNSClient(
            configuration: .init(authenticationMethod:.jwt(privateKey: .init(),
                                                           keyIdentifier: "",
                                                           teamIdentifier: ""),
                                 environment: .development),
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
            byteBufferAllocator: .init())
    }
}
