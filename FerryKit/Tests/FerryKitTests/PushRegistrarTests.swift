import Foundation
import Synchronization
import Testing
@testable import FerryKit

private let A = URL(string: "https://a.tail1.ts.net/ferry/")!
private let B = URL(string: "https://b.tail1.ts.net/ferry/")!
/// A relay the app used before (the first TestFlight builds had their own).
private let oldRelay = "https://old-relay.example"

private func addr(_ id: String) -> RelayAddress {
    RelayAddress(endpoint: URL(string: "https://push.nightdrive.sh/push/\(id)")!, secret: "s-\(id)")
}

private func oldAddr(_ id: String) -> RelayAddress {
    RelayAddress(endpoint: URL(string: "\(oldRelay)/push/\(id)")!, secret: "s-\(id)")
}

private func rec(_ m: URL, _ key: String, _ id: String = "r0", subscribed: Bool = true, checked: Date = t0) -> PushRecord {
    PushRecord(machine: m, vapid: key, address: addr(id), subscribed: subscribed, checked: checked)
}

private func oldRec(_ m: URL, _ key: String, _ id: String = "o0", checked: Date = t0) -> PushRecord {
    PushRecord(machine: m, vapid: key, address: oldAddr(id), subscribed: true, checked: checked)
}

private func state(_ records: [PushRecord] = [], enabled: Bool = true, token: String? = "t") -> PushState {
    var s = PushState()
    s.enabled = enabled
    s.token = token
    s.records = records
    return s
}

@Suite struct PushPlannerTests {
    @Test func disabledDropsEverything() {
        let r = rec(A, "kA")
        #expect(PushPlanner.actions(relay: relay, state([r], enabled: false), known: [A: "kA"], reachable: [A], now: t0) == [.drop(r)])
    }

    @Test func noTokenDoesNothing() {
        #expect(PushPlanner.actions(relay: relay, state(token: nil), known: [A: "kA"], reachable: [A], now: t0) == [])
    }

    @Test func registersAMachineWithAKey() {
        #expect(PushPlanner.actions(relay: relay, state(), known: [A: "kA"], reachable: [A], now: t0) == [.register(machine: A, vapid: "kA")])
    }

    @Test func noRegisterWithoutAKey() {
        #expect(PushPlanner.actions(relay: relay, state(), known: [A: String?.none], reachable: [A], now: t0) == [])
    }

    @Test func subscribesOnlyWhenReachable() {
        let r = rec(A, "kA", subscribed: false)
        #expect(PushPlanner.actions(relay: relay, state([r]), known: [A: "kA"], reachable: [A], now: t0) == [.subscribe(r)])
        #expect(PushPlanner.actions(relay: relay, state([r]), known: [A: "kA"], reachable: [], now: t0) == [])
    }

    @Test func forgottenMachineIsDropped() {
        let r = rec(A, "kA")
        #expect(PushPlanner.actions(relay: relay, state([r]), known: [B: String?.none], reachable: [], now: t0) == [.drop(r)])
    }

    @Test func changedKeyRegistersAgain() {
        let r = rec(A, "kA")
        #expect(PushPlanner.actions(relay: relay, state([r]), known: [A: "kA2"], reachable: [A], now: t0)
                == [.drop(r), .register(machine: A, vapid: "kA2")])
    }

    @Test func keyNotKnownYetKeepsTheRecord() {   // not polled since launch
        let r = rec(A, "kA")
        #expect(PushPlanner.actions(relay: relay, state([r]), known: [A: String?.none], reachable: [], now: t0) == [])
    }

    @Test func movesToTheRelayInUse() {   // registers first: the old address works until the new one does
        let r = oldRec(A, "kA")
        #expect(PushPlanner.actions(relay: relay, state([r]), known: [A: "kA"], reachable: [A], now: t0)
                == [.register(machine: A, vapid: "kA"), .drop(r)])
    }

    @Test func movesWithTheKeyItHasBeforeAPoll() {
        let r = oldRec(A, "kA")
        #expect(PushPlanner.actions(relay: relay, state([r]), known: [A: String?.none], reachable: [A], now: t0)
                == [.register(machine: A, vapid: "kA"), .drop(r)])
    }

    @Test func movesOnlyWhenTheComputerAnswers() {   // it couldn't take the new address, so the old one stays
        let r = oldRec(A, "kA", checked: t0.addingTimeInterval(-86401))   // and isn't checked at the old relay either
        #expect(PushPlanner.actions(relay: relay, state([r]), known: [A: "kA"], reachable: [], now: t0) == [])
    }

    @Test func checksADayLater() {
        let old = rec(A, "kA", checked: t0.addingTimeInterval(-86401))
        let fresh = rec(B, "kB", "r1", checked: t0.addingTimeInterval(-86000))
        #expect(PushPlanner.actions(relay: relay, state([old, fresh]), known: [A: "kA", B: "kB"], reachable: [A, B], now: t0) == [.check(old)])
    }
}

/// The relay, in memory: hands out r1, r2, … and remembers what it was asked.
private actor FakeRelay: PushRelay {
    var calls: [String] = []
    var live: Set<String> = []
    var failing = false
    var failingDelete = false
    var refused: Set<String> = []   // VAPID keys the relay answers 400 to
    var oldRelayGone = false        // the old relay's name no longer resolves
    let base = relay
    private var next = 0

    func setFailing(_ f: Bool) { failing = f }
    func setFailingDelete(_ f: Bool) { failingDelete = f }
    func setRefused(_ keys: Set<String>) { refused = keys }
    func setLive(_ ids: Set<String>) { live = ids }
    func setOldRelayGone(_ g: Bool) { oldRelayGone = g }

    func register(token: String, env: APNsEnvironment, vapid: String) async throws -> RelayAddress {
        calls.append("register \(token) \(env.rawValue) \(vapid)")
        if failing { throw FerryError.unreachable(machine: "push.nightdrive.sh") }
        if refused.contains(vapid) { throw FerryError.refused(status: 400, message: "Expected a P-256 key") }
        next += 1
        live.insert("r\(next)")
        return addr("r\(next)")
    }

    func exists(_ address: RelayAddress) async throws -> Bool {
        calls.append("exists \(address.id)")
        if failing { throw FerryError.unreachable(machine: "push.nightdrive.sh") }
        return live.contains(address.id)
    }

    func delete(_ address: RelayAddress) async throws {
        calls.append("delete \(address.id)")
        if oldRelayGone, !address.isAt(relay) { throw FerryError.unreachable(machine: "old-relay.example") }
        if failingDelete { throw FerryError.unreachable(machine: "push.nightdrive.sh") }
        live.remove(address.id)
    }
}

/// The tests' time, moved on by hand (the registrar's retries and the poll's rhythm are in seconds and minutes).
final class TestClock: Sendable {
    let date = Mutex(t0)
    var now: Date { date.withLock { $0 } }
    func advance(_ s: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(s) } }
}

@MainActor @Suite struct PushRegistrarTests {
    let keys = PushKeys.generate()

    private func make(_ relay: FakeRelay, _ fake: FakeBackend, _ clock: TestClock = TestClock(),
                      defaults: UserDefaults? = nil) throws -> (PushRegistrar, PushStore) {
        let store = PushStore(defaults: try defaults ?? #require(UserDefaults(suiteName: UUID().uuidString)))
        let keys = keys
        return (PushRegistrar(relay: relay, backend: fake, store: store, keys: { keys },
                              now: { clock.date.withLock { $0 } }), store)
    }

    @Test func firstSyncRegistersAndSubscribes() async throws {
        let relay = FakeRelay(), fake = FakeBackend()
        let (reg, store) = try make(relay, fake)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .sandbox)
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(await relay.calls == ["register t sandbox kA"])
        #expect(await fake.calls == ["subscribe r1 a.tail1.ts.net"])
        #expect(reg.state.records == [rec(A, "kA", "r1", subscribed: true, checked: t0)])
        #expect(store.load() == reg.state)
    }

    /// A forgotten phone's subscriptions were dropped by the computers: added again, it subscribes again everywhere,
    /// at once on the computers that answer and on the others when they do
    @Test func subscribingAgainEverywhere() async throws {
        let relay = FakeRelay(), fake = FakeBackend()
        let (reg, store) = try make(relay, fake)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await reg.sync(known: [A: "kA", B: "kB"], reachable: [A, B])
        #expect(reg.state.records.map(\.subscribed) == [true, true])
        reg.subscribeAgain()
        #expect(reg.state.records.map(\.subscribed) == [false, false])
        #expect(store.load() == reg.state)
        await reg.sync(known: [A: "kA", B: "kB"], reachable: [A])
        #expect(await fake.calls.filter { $0.hasPrefix("subscribe") }.count == 3)
        #expect(await relay.calls == ["register t production kA", "register t production kB"])   // the same addresses
        #expect(reg.state.records.first { $0.machine == A }?.subscribed == true)
        #expect(reg.state.records.first { $0.machine == B }?.subscribed == false)
        await reg.sync(known: [A: "kA", B: "kB"], reachable: [A, B])
        #expect(reg.state.records.map(\.subscribed) == [true, true])
    }

    @Test func checkFindsTheAddressGoneAndRegistersAgain() async throws {   // Review Focus 4
        let relay = FakeRelay(), fake = FakeBackend(), clock = TestClock()
        let (reg, _) = try make(relay, fake, clock)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await reg.sync(known: [A: "kA"], reachable: [A])
        await relay.setLive([])   // the relay lost its database
        clock.advance(86401)
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(await relay.calls == ["register t production kA", "exists r1", "register t production kA"])
        #expect(await fake.calls == ["subscribe r1 a.tail1.ts.net", "subscribe r2 a.tail1.ts.net"])
        #expect(reg.state.records.map(\.address.id) == ["r2"])
    }

    @Test func checkFindsItThereAndSubscribesAgain() async throws {   // the computer may have dropped it quietly
        let relay = FakeRelay(), fake = FakeBackend(), clock = TestClock()
        let (reg, _) = try make(relay, fake, clock)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await reg.sync(known: [A: "kA"], reachable: [A])
        clock.advance(86401)
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(await fake.calls == ["subscribe r1 a.tail1.ts.net", "subscribe r1 a.tail1.ts.net"])
        #expect(reg.state.records.first?.checked == t0.addingTimeInterval(86401))
    }

    @Test func newTokenDropsTheOldAddresses() async throws {
        let relay = FakeRelay(), fake = FakeBackend()
        let (reg, _) = try make(relay, fake)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await reg.sync(known: [A: "kA"], reachable: [A])
        await reg.setToken("t2", env: .production)
        #expect(reg.state.records.isEmpty)
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(await relay.calls == ["register t production kA", "delete r1", "register t2 production kA"])
    }

    @Test func sameTokenChangesNothing() async throws {   // iOS hands the token over on every launch
        let relay = FakeRelay(), fake = FakeBackend()
        let (reg, _) = try make(relay, fake)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await reg.sync(known: [A: "kA"], reachable: [A])
        await reg.setToken("t", env: .production)
        #expect(reg.state.records.count == 1)
        #expect(await relay.calls == ["register t production kA"])
    }

    @Test func turnedOffDeletesAndUnsubscribes() async throws {
        let relay = FakeRelay(), fake = FakeBackend()
        let (reg, _) = try make(relay, fake)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await reg.sync(known: [A: "kA", B: "kB"], reachable: [A, B])
        await fake.setDown([B])
        await reg.setEnabled(false)
        #expect(reg.state.records.isEmpty)
        #expect(reg.state.enabled == false)
        #expect(await relay.calls.filter { $0.hasPrefix("delete") }.sorted() == ["delete r1", "delete r2"])
        #expect(await fake.calls.filter { $0.hasPrefix("unsubscribe") }.count == 2)
    }

    @Test func aFailingRelayIsQuietAndTriedAgainLater() async throws {
        let relay = FakeRelay(), fake = FakeBackend(), clock = TestClock()
        let (reg, _) = try make(relay, fake, clock)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await relay.setFailing(true)
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(reg.state.records.isEmpty)
        await relay.setFailing(false)
        await reg.sync(known: [A: "kA"], reachable: [A])   // every poll would hit a relay that is down: wait a minute
        #expect(await relay.calls.count == 1)
        clock.advance(61)
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(reg.state.records.count == 1)
    }

    @Test func turnedOffOfflineDeletesLater() async throws {   // review: off must stay off
        let relay = FakeRelay(), fake = FakeBackend(), clock = TestClock()
        let (reg, store) = try make(relay, fake, clock)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await reg.sync(known: [A: "kA"], reachable: [A])
        await relay.setFailingDelete(true)
        await fake.setDown([A])
        await reg.setEnabled(false)
        #expect(reg.state.records.isEmpty)
        #expect(reg.state.pendingDeletes.map(\.id) == ["r1"])
        #expect(store.load().pendingDeletes.map(\.id) == ["r1"])   // survives a relaunch
        await relay.setFailingDelete(false)
        clock.advance(61)
        await reg.sync(known: [A: "kA"], reachable: [])
        #expect(reg.state.pendingDeletes.isEmpty)
        #expect(await relay.live.isEmpty)
    }

    @Test func aRefusedComputerDoesntBlockTheOthers() async throws {
        let relay = FakeRelay(), fake = FakeBackend()
        let (reg, _) = try make(relay, fake)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await relay.setRefused(["kA"])
        await reg.sync(known: [A: "kA", B: "kB"], reachable: [A, B])
        #expect(reg.state.records.map(\.machine) == [B])
    }

    @Test func addressTellsTheMachine() async throws {
        let relay = FakeRelay(), fake = FakeBackend()
        let (reg, _) = try make(relay, fake)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(reg.machine(forAddress: "r1") == A)
        #expect(reg.machine(forAddress: "nope") == nil)
    }

    /// A TestFlight install from before push.nightdrive.sh: its addresses are at the old relay.
    private func installedBefore(_ defaults: UserDefaults, pendingDelete: Bool = false) {
        var s = state([oldRec(A, "kA")])
        if pendingDelete { s.pendingDeletes = [oldAddr("o1")] }
        PushStore(defaults: defaults).save(s)
    }

    @Test func movesOverFromAnOldRelay() async throws {
        let relay = FakeRelay(), fake = FakeBackend()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        installedBefore(defaults)
        let (reg, _) = try make(relay, fake, defaults: defaults)
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(await relay.calls == ["register t production kA", "delete o0"])
        #expect(await fake.calls == ["subscribe r1 a.tail1.ts.net", "unsubscribe o0 a.tail1.ts.net"])
        #expect(reg.state.records == [rec(A, "kA", "r1", subscribed: true, checked: t0)])
        #expect(reg.state.pendingDeletes.isEmpty)
    }

    @Test func movesOverWhenTheOldRelayIsGone() async throws {   // the old relay removed before the phone moved
        let relay = FakeRelay(), fake = FakeBackend()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        installedBefore(defaults, pendingDelete: true)
        await relay.setOldRelayGone(true)
        let (reg, _) = try make(relay, fake, defaults: defaults)
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(reg.state.records.map(\.address.id) == ["r1"])
        #expect(reg.state.pendingDeletes.isEmpty)   // not tried forever: the old relay's addresses went with it
        await reg.sync(known: [A: "kA"], reachable: [A])
        #expect(await relay.calls == ["delete o1", "register t production kA", "delete o0"])
    }

    @Test func stateSurvivesARelaunch() async throws {
        let relay = FakeRelay(), fake = FakeBackend()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let (reg, _) = try make(relay, fake, defaults: defaults)
        await reg.setEnabled(true)
        await reg.setToken("t", env: .production)
        await reg.sync(known: [A: "kA"], reachable: [A])
        let (again, _) = try make(relay, fake, defaults: defaults)
        #expect(again.state == reg.state)
    }
}
