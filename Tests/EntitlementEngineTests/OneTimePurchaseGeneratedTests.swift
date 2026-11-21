import Foundation
import Synchronization
import Testing
@testable import IAPEntitlementEngine

// Third review: generated sequences against an independent oracle.
//
// Apple oracle. Apple says to go by the notification signed last, because it holds the newest
// snapshot of the transaction. A refund carries `revocationDate`, a reversal its `signedDate`.
// So: a refund stands if no reversal signed after it has been seen, and of the refunds that
// stand the newest one says how much is taken back (a tie on the date takes the larger). A
// prorated refund of a consumable takes round(quantity * pct / 100000) units, and of anything
// else nothing unless it is 100%. An event that would grant units to nobody throws and counts
// as not seen. Units must never be handed to a record without an account.
//
// Google oracle. A void is never undone, so the units taken back are the largest any seen event
// named: all for `.full`, for purchaseState 1 and for a voided pending purchase;
// quantity - refundableQuantity for `.partial`; none without `voided`. A pending purchase that is
// not voided is not seen.

final class LedgerStore: PurchaseStoreDelegate, @unchecked Sendable {
    struct State {
        var records: [String: PurchaseRecord] = [:]
        var balance = 0
        var saves = 0
        /// Units moved while the record named nobody.
        var unitsToNobody = 0
    }
    let state = Mutex(State())

    var balance: Int { state.withLock { $0.balance } }
    var unitsToNobody: Int { state.withLock { $0.unitsToNobody } }
    var saves: Int { state.withLock { $0.saves } }
    func record(_ id: String, _ store: PurchaseRecord.Store = .appStore) -> PurchaseRecord? {
        state.withLock { $0.records["\(store.rawValue)|\(id)"] }
    }

    func purchase(transactionID: String, store: PurchaseRecord.Store) async throws -> PurchaseRecord? {
        record(transactionID, store)
    }

    func savePurchase(_ record: PurchaseRecord, replacing previous: PurchaseRecord?, quantityChange: Int) async throws {
        try state.withLock {
            let key = "\(record.store.rawValue)|\(record.transactionID)"
            guard $0.records[key]?.revision == previous?.revision else { throw TestFailure.boom }
            $0.records[key] = record
            $0.balance += quantityChange
            $0.saves += 1
            if record.accountID == nil { $0.unitsToNobody += abs(quantityChange) }
        }
    }
}

/// Answers the read with what an earlier moment held, and saves to the real store.
final class StaleView: PurchaseStoreDelegate {
    let base: LedgerStore
    let stale: PurchaseRecord?
    init(base: LedgerStore, stale: PurchaseRecord?) { self.base = base; self.stale = stale }
    func purchase(transactionID: String, store: PurchaseRecord.Store) async throws -> PurchaseRecord? { stale }
    func savePurchase(_ record: PurchaseRecord, replacing previous: PurchaseRecord?, quantityChange: Int) async throws {
        try await base.savePurchase(record, replacing: previous, quantityChange: quantityChange)
    }
}

let r3coins = OneTimeProduct(id: "coins.100", kind: .consumable)
let r3unlock = OneTimeProduct(id: "pro.unlock", kind: .nonConsumable)
let r3pass = OneTimeProduct(id: "season.pass", kind: .nonRenewing(duration: 30 * 86_400))

func r3engine(_ store: any PurchaseStoreDelegate) -> PurchaseEngine {
    PurchaseEngine(storeDelegate: store, products: [r3coins, r3unlock, r3pass], now: { now })
}

struct AppleEvent: CustomStringConvertible, Sendable {
    enum Kind: Sendable { case plain, refund, reversal }
    var kind: Kind
    /// Seconds after `now`: the refund's revocationDate or the reversal's signedDate.
    var at: Double = 0
    /// nil is a full refund.
    var pct: Int64?
    var account = true
    var restored = false

    var description: String {
        var text: String
        switch kind {
        case .plain: text = restored ? "restoredCopy" : "purchase"
        case .refund: text = pct.map { "prorated(\($0))@\(Int(at))" } ?? "fullRefund@\(Int(at))"
        case .reversal: text = "reversal@\(Int(at))"
        }
        return account ? text : text + "/noAccount"
    }

    func transaction(product: String, quantity: Int32) -> AppStoreTransaction {
        var transaction = AppStoreTransaction(
            productId: product, originalTransactionId: "tx-1",
            revocationDate: kind == .refund ? now.addingTimeInterval(at) : nil,
            transactionId: restored ? "tx-9" : "tx-1", quantity: quantity,
            purchaseDate: now.addingTimeInterval(-60), appAccountToken: account ? "buyer" : nil)
        if kind == .refund {
            transaction.revocationType = pct == nil ? "REFUND_FULL" : "REFUND_PRORATED"
            transaction.revocationPercentage = pct ?? 100_000
        }
        return transaction
    }

    func send(to engine: PurchaseEngine, product: String, quantity: Int32) async throws -> PurchaseResult {
        if kind == .reversal {
            return try await engine.processAppStoreRefundReversal(
                notifier: RecordingNotifier(), transaction: transaction(product: product, quantity: quantity),
                signedDate: now.addingTimeInterval(at))
        }
        return try await engine.processAppStoreTransaction(
            notifier: RecordingNotifier(), transaction: transaction(product: product, quantity: quantity))
    }
}

/// The oracle described at the top of the file.
struct AppleOracle {
    let units: Int
    let isConsumable: Bool
    var exists = false
    /// Some event that was accepted named the buyer.
    var hasAccount = false
    var lastReversal: Double?
    var refunds: [(at: Double, units: Int)] = []

    func taken(_ event: AppleEvent) -> Int {
        guard let pct = event.pct else { return units }
        if isConsumable { return min(units, Int((Double(units) * Double(pct) / 100_000).rounded())) }
        return pct >= 100_000 ? units : 0
    }

    var held: Int {
        let standing = refunds.filter { $0.at >= (lastReversal ?? -.infinity) }
        guard let newest = standing.map(\.at).max() else { return units }
        return units - standing.filter { $0.at == newest }.map(\.units).max()!
    }

    /// Returns false when the event must throw `missingAccountID`.
    mutating func see(_ event: AppleEvent) -> Bool {
        var next = self
        switch event.kind {
        case .plain: break
        case .refund: next.refunds.append((event.at, taken(event)))
        case .reversal: next.lastReversal = max(event.at, lastReversal ?? event.at)
        }
        // Units that go to the buyer have to go to someone.
        if next.held > (exists ? held : 0), !hasAccount, !event.account { return false }
        next.exists = true
        next.hasAccount = hasAccount || event.account
        self = next
        return true
    }
}

func sequences<T>(of alphabet: [T], upTo length: Int) -> [[T]] {
    var current: [[T]] = alphabet.map { [$0] }
    var all = current
    for _ in 1..<length {
        current = current.flatMap { head in alphabet.map { head + [$0] } }
        all += current
    }
    return all
}

func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { index -> [[T]] in
        var rest = items
        let head = rest.remove(at: index)
        return permutations(rest).map { [head] + $0 }
    }
}

struct Wrong { var count = 0; var examples: [String] = [] }

func note(_ bucket: inout [String: Wrong], _ key: String, _ example: @autoclosure () -> String) {
    bucket[key, default: Wrong()].count += 1
    if bucket[key]!.examples.count < 6 { bucket[key]!.examples.append(example()) }
}

func report(_ title: String, _ total: Int, _ bucket: [String: Wrong]) -> String {
    var lines = ["\(title): \(bucket.values.map(\.count).reduce(0, +)) wrong of \(total)"]
    for (key, wrong) in bucket.sorted(by: { $0.key < $1.key }) {
        lines.append("  [\(key)] \(wrong.count)")
        for example in wrong.examples { lines.append("      \(example)") }
    }
    return lines.joined(separator: "\n")
}

/// Runs one Apple sequence and names what went wrong, or returns nil.
func runApple(_ sequence: [AppleEvent], product: String, quantity: Int32, isConsumable: Bool) async -> (String, String)? {
    let units = isConsumable ? Int(quantity) : 1
    let store = LedgerStore()
    let engine = r3engine(store)
    var oracle = AppleOracle(units: units, isConsumable: isConsumable)
    var reported = 0
    for (index, event) in sequence.enumerated() {
        let expectedToPass = oracle.see(event)
        do {
            let result = try await event.send(to: engine, product: product, quantity: quantity)
            reported += result.quantityChange
            if !expectedToPass { return ("accepted an event that grants to nobody", "step \(index)") }
        } catch EntitlementError.missingAccountID {
            if expectedToPass { return ("threw missingAccountID for an event that grants nothing new", "step \(index)") }
        } catch {
            return ("threw \(error)", "step \(index)")
        }
        let record = store.record("tx-1")
        if oracle.exists != (record != nil) { return ("record existence", "step \(index)") }
        guard let record else { continue }
        if reported != store.balance || store.balance != record.remainingQuantity {
            return ("books disagree", "step \(index): reported \(reported), balance \(store.balance), record \(record.remainingQuantity)")
        }
        if record.remainingQuantity != oracle.held {
            let key = record.remainingQuantity < oracle.held ? "buyer holds too little" : "buyer holds too much"
            return (key, "step \(index): holds \(record.remainingQuantity), expected \(oracle.held)")
        }
        if store.unitsToNobody != 0 { return ("units moved on a record with no account", "step \(index)") }
        if oracle.hasAccount != (record.accountID != nil) { return ("the record does not name the buyer it was told", "step \(index)") }
    }
    return nil
}

@Suite("One-time purchases: generated sequences")
struct OneTimePurchaseGeneratedTests {
    static let appleAlphabet: [AppleEvent] = [
        AppleEvent(kind: .plain),
        AppleEvent(kind: .plain, account: false),
        AppleEvent(kind: .plain, restored: true),
        AppleEvent(kind: .refund, at: 100),
        AppleEvent(kind: .refund, at: 100, account: false),
        AppleEvent(kind: .refund, at: 300),
        AppleEvent(kind: .refund, at: 100, pct: 33_333),
        AppleEvent(kind: .refund, at: 100, pct: 66_667),
        AppleEvent(kind: .refund, at: 300, pct: 33_333),
        AppleEvent(kind: .refund, at: 300, pct: 66_667),
        AppleEvent(kind: .reversal, at: 200),
        AppleEvent(kind: .reversal, at: 200, account: false),
        AppleEvent(kind: .reversal, at: 400),
    ]

    /// Every generated sequence has to end with what the stores' rules say the buyer holds.
    @Test(arguments: [
        ("coins.100", Int32(3), true), ("coins.100", Int32(1), true),
        ("pro.unlock", Int32(1), false), ("season.pass", Int32(1), false), ("pro.unlock", Int32(3), false),
    ])
    func appleSequencesMatchTheOracle(product: String, quantity: Int32, isConsumable: Bool) async {
        let all = sequences(of: Self.appleAlphabet, upTo: 4)
        var wrong: [String: Wrong] = [:]
        for sequence in all {
            if let (key, detail) = await runApple(sequence, product: product, quantity: quantity, isConsumable: isConsumable) {
                note(&wrong, key, "\(sequence) -> \(detail)")
            }
        }
        let text = report("Apple \(product) x\(quantity)", all.count, wrong)
        print(text)
        #expect(wrong.isEmpty, "\(text)")
    }

    /// Five events, with accounts throughout, so the count stays small.
    @Test func appleSequencesOfFiveMatchTheOracle() async {
        let alphabet = Self.appleAlphabet.filter { $0.account && !$0.restored }
        let all = sequences(of: alphabet, upTo: 5)
        var wrong: [String: Wrong] = [:]
        for sequence in all {
            if let (key, detail) = await runApple(sequence, product: "coins.100", quantity: 3, isConsumable: true) {
                note(&wrong, key, "\(sequence) -> \(detail)")
            }
        }
        let text = report("Apple coins x3, five events", all.count, wrong)
        print(text)
        #expect(wrong.isEmpty, "\(text)")
    }

    /// Needs no oracle: the same events in another order must end with the same total.
    @Test func theSameAppleEventsInAnyOrderEndTheSame() async {
        let alphabet = Self.appleAlphabet.filter { $0.account && !$0.restored }
        var wrong: [String: Wrong] = [:]
        var sets = 0
        func combos(_ start: Int, _ picked: [Int], _ size: Int, _ out: inout [[Int]]) {
            if picked.count == size { out.append(picked); return }
            for index in start..<alphabet.count { combos(index, picked + [index], size, &out) }
        }
        for size in 2...4 {
            var picks: [[Int]] = []
            combos(0, [], size, &picks)
            for pick in picks {
                sets += 1
                var ends: [Int: [AppleEvent]] = [:]
                for order in permutations(pick) {
                    let store = LedgerStore()
                    let engine = r3engine(store)
                    let events = order.map { alphabet[$0] }
                    for event in events { _ = try? await event.send(to: engine, product: "coins.100", quantity: 3) }
                    ends[store.record("tx-1")?.remainingQuantity ?? -1] = ends[store.record("tx-1")?.remainingQuantity ?? -1] ?? events
                }
                if ends.count > 1 {
                    note(&wrong, "order changes the total (\(size) events)",
                         ends.sorted { $0.key < $1.key }.map { "\($0.value) holds \($0.key)" }.joined(separator: "  BUT  "))
                }
            }
        }
        let text = report("Apple order independence, coins x3", sets, wrong)
        print(text)
        #expect(wrong.isEmpty, "\(text)")
    }

    // MARK: Google

    struct GoogleEvent: CustomStringConvertible {
        var state: Int
        var refundable: Int?
        var voided: GooglePlayProductPurchase.Voided?
        var account: Bool
        var description: String {
            "state\(state)/rq:\(refundable.map(String.init) ?? "nil")/\(voided.map { "\($0)" } ?? "notVoided")\(account ? "" : "/noAccount")"
        }
    }

    @Test(arguments: [("coins.100", Int?.none, true), ("coins.100", Int?.some(3), true),
                      ("pro.unlock", Int?.none, false), ("pro.unlock", Int?.some(3), false),
                      ("season.pass", Int?.some(3), false)])
    func googleSequencesMatchTheOracle(product: String, quantity: Int?, isConsumable: Bool) async {
        var alphabet: [GoogleEvent] = []
        for state in 0...2 {
            for refundable in [Int?.none, 0, 1, 2, 3] {
                for voided in [GooglePlayProductPurchase.Voided?.none, .full, .partial] {
                    for account in [true, false] {
                        alphabet.append(GoogleEvent(state: state, refundable: refundable, voided: voided, account: account))
                    }
                }
            }
        }
        let all = sequences(of: alphabet, upTo: 2) + sequences(of: alphabet.filter(\.account), upTo: 3).filter { $0.count == 3 }
        let bought = max(1, quantity ?? 1)
        let units = isConsumable ? bought : 1
        var wrong: [String: Wrong] = [:]
        for sequence in all {
            let store = LedgerStore()
            let engine = r3engine(store)
            var exists = false
            var taken = 0
            var reported = 0
            var failure: (String, String)?
            for (index, event) in sequence.enumerated() {
                var all = event.voided == .full || event.state == 1 || (event.state == 2 && event.voided != nil)
                var named = 0
                if event.voided == .partial {
                    named = bought - min(bought, max(0, event.refundable ?? bought))
                    if named == bought { all = true }
                }
                let pending = event.state == 2 && event.voided == nil
                let eventTakes = all ? units : (isConsumable ? named : 0)
                let nextTaken = max(taken, eventTakes)
                let mustThrow = !pending && !exists && units - nextTaken > 0 && !event.account
                do {
                    let result = try await engine.processGooglePlayPurchase(
                        notifier: RecordingNotifier(), productID: product, purchaseToken: "token",
                        purchase: GooglePlayProductPurchase(
                            purchaseState: event.state, quantity: quantity, refundableQuantity: event.refundable,
                            obfuscatedExternalAccountId: event.account ? "buyer" : nil),
                        voided: event.voided)
                    reported += result.quantityChange
                    if mustThrow { failure = ("accepted an event that grants to nobody", "step \(index)"); break }
                    if pending {
                        if result.outcome != .pending || result.didSave { failure = ("pending saved", "step \(index)"); break }
                    } else {
                        exists = true
                        taken = nextTaken
                    }
                } catch EntitlementError.missingAccountID {
                    if !mustThrow { failure = ("threw missingAccountID wrongly", "step \(index)"); break }
                } catch {
                    failure = ("threw \(error)", "step \(index)"); break
                }
                let record = store.record("token", .googlePlay)
                if exists != (record != nil) { failure = ("record existence", "step \(index)"); break }
                guard let record else { continue }
                if reported != store.balance || store.balance != record.remainingQuantity {
                    failure = ("books disagree", "step \(index)"); break
                }
                if record.remainingQuantity != units - taken {
                    failure = ("wrong total", "step \(index): holds \(record.remainingQuantity), expected \(units - taken)"); break
                }
                if store.unitsToNobody != 0 { failure = ("units moved on a record with no account", "step \(index)"); break }
            }
            if let failure { note(&wrong, failure.0, "\(sequence) -> \(failure.1)") }
        }
        let text = report("Google \(product) x\(quantity.map(String.init) ?? "nil")", all.count, wrong)
        print(text)
        #expect(wrong.isEmpty, "\(text)")
    }

    // MARK: Races

    /// Every way to interleave the reads and saves of two and three calls. A call that throws
    /// is sent again afterwards, as a store resends a webhook that failed.
    @Test func appleRacesEndWhereTheOracleSays() async {
        let alphabet: [AppleEvent] = [
            AppleEvent(kind: .plain),
            AppleEvent(kind: .refund, at: 100),
            AppleEvent(kind: .refund, at: 300),
            AppleEvent(kind: .refund, at: 300, pct: 33_333),
            AppleEvent(kind: .refund, at: 100, pct: 66_667),
            AppleEvent(kind: .reversal, at: 200),
            AppleEvent(kind: .reversal, at: 400),
        ]
        func interleavings(_ calls: Int) -> [[(call: Int, isSave: Bool)]] {
            var out: [[(call: Int, isSave: Bool)]] = []
            func extend(_ prefix: [(call: Int, isSave: Bool)], _ read: Set<Int>, _ saved: Set<Int>) {
                if saved.count == calls { out.append(prefix); return }
                for call in 0..<calls {
                    if !read.contains(call) {
                        extend(prefix + [(call, false)], read.union([call]), saved)
                    } else if !saved.contains(call) {
                        extend(prefix + [(call, true)], read, saved.union([call]))
                    }
                }
            }
            extend([], [], [])
            return out
        }
        var wrong: [String: Wrong] = [:]
        var runs = 0
        for calls in 2...3 {
            let orders = interleavings(calls)
            // Start from nothing, and from a purchase already recorded.
            for seeded in [false, true] {
                for events in sequences(of: alphabet, upTo: calls) where events.count == calls {
                    for order in orders {
                        runs += 1
                        let store = LedgerStore()
                        var oracle = AppleOracle(units: 3, isConsumable: true)
                        if seeded {
                            _ = try? await AppleEvent(kind: .plain).send(to: r3engine(store), product: "coins.100", quantity: 3)
                            _ = oracle.see(AppleEvent(kind: .plain))
                        }
                        var stale: [Int: PurchaseRecord?] = [:]
                        var thrown: [Int] = []
                        var reported = store.balance
                        for step in order {
                            if !step.isSave {
                                stale[step.call] = store.record("tx-1")
                            } else {
                                let view = StaleView(base: store, stale: stale[step.call]!)
                                do {
                                    reported += try await events[step.call].send(
                                        to: r3engine(view), product: "coins.100", quantity: 3).quantityChange
                                } catch {
                                    thrown.append(step.call)
                                }
                            }
                        }
                        for call in thrown {
                            if let result = try? await events[call].send(to: r3engine(store), product: "coins.100", quantity: 3) {
                                reported += result.quantityChange
                            } else {
                                note(&wrong, "retry threw", "\(events) \(order)")
                            }
                        }
                        for event in events { _ = oracle.see(event) }
                        // Whatever the oracle says, a race must end where some order of the
                        // same calls, one after another, would have ended.
                        var serial: Set<Int> = []
                        for order in permutations(Array(events.indices)) {
                            let alone = LedgerStore()
                            if seeded { _ = try? await AppleEvent(kind: .plain).send(to: r3engine(alone), product: "coins.100", quantity: 3) }
                            for index in order { _ = try? await events[index].send(to: r3engine(alone), product: "coins.100", quantity: 3) }
                            serial.insert(alone.record("tx-1")?.remainingQuantity ?? -1)
                        }
                        let record = store.record("tx-1")
                        let name = "seeded:\(seeded) \(events) order \(order.map { "\($0.isSave ? "S" : "R")\($0.call)" }.joined(separator: " ")) thrown \(thrown)"
                        if reported != store.balance || store.balance != record?.remainingQuantity {
                            note(&wrong, "books disagree", name)
                        } else if !serial.contains(record?.remainingQuantity ?? -1) {
                            note(&wrong, "ends where no serial order ends", "\(name): holds \(record?.remainingQuantity ?? -1), serial \(serial)")
                        } else if record?.remainingQuantity != oracle.held {
                            note(&wrong, "wrong total", "\(name): holds \(record?.remainingQuantity ?? -1), expected \(oracle.held)")
                        }
                    }
                }
            }
        }
        let text = report("Apple races", runs, wrong)
        print(text)
        #expect(wrong.isEmpty, "\(text)")
    }
}
