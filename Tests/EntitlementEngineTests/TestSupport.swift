import APNSCore
import Foundation
import Synchronization
import Testing
@testable import IAPEntitlementEngine

let now = Date(timeIntervalSince1970: 1_800_000_000)
let orderID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

func milliseconds(_ date: Date) -> String { String(date.millisecondsSince1970) }

let catalog = ProductCatalog(weekly: "weekly", monthly: "monthly", yearly: "yearly")

final class RecordingStore: EntitlementStoreDelegate {
    private let state = Mutex<[(order: Order, previous: Order)]>([])
    let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    var updates: [(order: Order, previous: Order)] { state.withLock { $0 } }

    func updateOrder(_ order: Order, replacing previous: Order) async throws {
        if let failure { throw failure }
        state.withLock { $0.append((order, previous)) }
    }
}

struct Sent: Sendable, Equatable {
    let payload: IAPPayload
    let notification: EntitlementNotification
    let expiresAt: Date

    var collapseID: String { notification.collapseID }
}

/// The device most APNs tests push to.
func device(_ client: FakeAPNSClient) -> APNSEntitlementNotifier {
    APNSEntitlementNotifier(client: client, topic: "com.example.app", deviceToken: "abcd")
}

final class RecordingNotifier: EntitlementNotifier {
    private let state = Mutex<[Sent]>([])
    let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    var sent: [Sent] { state.withLock { $0 } }

    func send(_ payload: IAPPayload, for notification: EntitlementNotification, expiresAt: Date) async throws {
        if let failure { throw failure }
        state.withLock { $0.append(Sent(payload: payload, notification: notification, expiresAt: expiresAt)) }
    }
}

struct CapturedRequest: Sendable {
    let deviceToken: String
    let pushType: String
    let topic: String?
    let collapseID: String?
    let expiration: Int?
    let priority: Int?
    let json: Data
}

final class FakeAPNSClient: APNSClientProtocol {
    private let state = Mutex<[CapturedRequest]>([])
    let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    var requests: [CapturedRequest] { state.withLock { $0 } }

    func send(_ request: APNSRequest<some APNSMessage>) async throws -> APNSResponse {
        if let failure { throw failure }
        let captured = CapturedRequest(
            deviceToken: request.deviceToken,
            pushType: request.pushType.description,
            topic: request.topic,
            collapseID: request.collapseID,
            expiration: request.expiration?.expiration,
            priority: request.priority?.rawValue,
            json: try JSONEncoder().encode(request.message))
        state.withLock { $0.append(captured) }
        return APNSResponse()
    }

    func shutdown() async throws {}
}

enum TestFailure: Error, Equatable {
    case boom
}

final class TestClock: Sendable {
    private let state: Mutex<Date>

    init(_ date: Date) {
        state = Mutex(date)
    }

    var value: Date {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
