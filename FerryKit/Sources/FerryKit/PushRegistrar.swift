import Foundation

/// One computer's subscription: the relay address made for it, bound to its VAPID key.
public struct PushRecord: Codable, Equatable, Sendable {
    public var machine: URL
    public var vapid: String
    public var address: RelayAddress
    /// The computer has accepted `api/subscribe` with this address (as far as the app knows: see `checked`).
    public var subscribed: Bool
    /// When the relay last said the address exists. A computer drops a subscription quietly when the relay answers
    /// 404 or 410, so after a day the app checks and subscribes again.
    public var checked: Date

    public init(machine: URL, vapid: String, address: RelayAddress, subscribed: Bool, checked: Date) {
        self.machine = machine
        self.vapid = vapid
        self.address = address
        self.subscribed = subscribed
        self.checked = checked
    }
}

public struct PushState: Codable, Equatable, Sendable {
    public var enabled = false
    public var token: String?
    public var env: APNsEnvironment = .production
    public var records: [PushRecord] = []
    /// Relay addresses still to delete. Deleting the address is what stops the notifications (the computer then gets
    /// 404 and drops its subscription), so a delete that failed (offline, the relay down) is tried again until it
    /// succeeds, notifications on or off.
    public var pendingDeletes: [RelayAddress] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, token, env, records, pendingDeletes }

    public init(from decoder: any Decoder) throws {   // a state saved before pendingDeletes existed still loads
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        env = try c.decode(APNsEnvironment.self, forKey: .env)
        records = try c.decode([PushRecord].self, forKey: .records)
        pendingDeletes = try c.decodeIfPresent([RelayAddress].self, forKey: .pendingDeletes) ?? []
    }
}

/// The notification state in the App Group's defaults, beside the machine list.
public struct PushStore: @unchecked Sendable {   // UserDefaults is thread-safe
    static let key = "push"
    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> PushState {
        guard let data = defaults.data(forKey: Self.key),
              let s = try? JSONDecoder().decode(PushState.self, from: data) else { return PushState() }
        return s
    }

    public func save(_ s: PushState) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
    }
}

public enum PushAction: Equatable, Sendable {
    case register(machine: URL, vapid: String)
    case subscribe(PushRecord)
    case check(PushRecord)
    /// Delete at the relay and unsubscribe on the computer, both best effort.
    case drop(PushRecord)
}

/// What to do to keep every computer subscribed. Pure, so the rules are tested apart from the network.
public enum PushPlanner {
    public static let recheck: TimeInterval = 86400

    /// relay: the relay in use. known: every machine in the list → its VAPID key, nil until a poll has given one.
    /// reachable: answered the last poll.
    public static func actions(relay: URL, _ s: PushState, known: [URL: String?], reachable: Set<URL>,
                               now: Date) -> [PushAction] {
        guard s.enabled else { return s.records.map { .drop($0) } }
        guard s.token != nil else { return [] }
        var out: [PushAction] = []
        for r in s.records {
            guard let key = known[r.machine] else {   // forgotten
                out.append(.drop(r))
                continue
            }
            if !r.address.isAt(relay) {
                // An address at a relay the app used before (the TestFlight builds' first one): moved without waiting for that relay
                // to drop it, since it may simply stop answering. Only when the computer answers, so it takes the new
                // address at once, and the new one first, so the old one works until then. Never checked at the old
                // relay: a relay that is gone would hold up the sync.
                if reachable.contains(r.machine) {
                    out += [.register(machine: r.machine, vapid: key ?? r.vapid), .drop(r)]
                }
            } else if let key, key != r.vapid {   // the computer made a new key: the old address can't verify it
                out += [.drop(r), .register(machine: r.machine, vapid: key)]
            } else if now.timeIntervalSince(r.checked) > recheck {
                out.append(.check(r))
            } else if !r.subscribed, reachable.contains(r.machine) {
                out.append(.subscribe(r))
            }
        }
        let recorded = Set(s.records.map(\.machine))
        for (machine, key) in known.sorted(by: { $0.key.absoluteString < $1.key.absoluteString }) {
            if let key = key ?? nil, !recorded.contains(machine) { out.append(.register(machine: machine, vapid: key)) }
        }
        return out
    }
}

/// Carries the planner's actions out against the relay and the computers, and keeps the state on disk. Quiet: a
/// failure leaves the state as it was, to be tried again.
@MainActor public final class PushRegistrar {
    /// A relay that doesn't answer isn't asked again for this long: the app polls every 5 s.
    static let relayBackoff: TimeInterval = 60

    public private(set) var state: PushState

    private let relay: any PushRelay
    private let backend: any FerryBackend
    private let store: PushStore
    private let keys: @Sendable () throws -> PushKeys
    private let now: @Sendable () -> Date
    private var syncing = false
    private var relayRetry: Date?

    public init(relay: any PushRelay, backend: any FerryBackend, store: PushStore,
                keys: @escaping @Sendable () throws -> PushKeys, now: @escaping @Sendable () -> Date = Date.init) {
        self.relay = relay
        self.backend = backend
        self.store = store
        self.keys = keys
        self.now = now
        state = store.load()
    }

    public func machine(forAddress id: String) -> URL? {
        state.records.first { $0.address.id == id }?.machine
    }

    public func setEnabled(_ on: Bool) async {
        state.enabled = on
        save()
        if !on { await dropAll() }
    }

    /// iOS gives the token on every launch; only a different one starts over.
    public func setToken(_ token: String, env: APNsEnvironment) async {
        guard token != state.token || env != state.env else { return }
        await dropAll()
        state.token = token
        state.env = env
        save()
    }

    /// One at a time: a call while a sync runs returns at once (the next poll comes in 5 s).
    public func sync(known: [URL: String?], reachable: Set<URL>) async {
        guard !syncing else { return }
        if let retry = relayRetry, now() < retry { return }
        syncing = true
        defer { syncing = false }
        for address in state.pendingDeletes {
            if !address.isAt(relay.base) {   // saved by a build before the move: one more try, as in drop(_:)
                try? await relay.delete(address)
                state.pendingDeletes.removeAll { $0 == address }
                save()
                continue
            }
            guard (try? await relay.delete(address)) != nil else {
                relayRetry = now().addingTimeInterval(Self.relayBackoff)
                return
            }
            state.pendingDeletes.removeAll { $0 == address }
            save()
        }
        guard let keys = try? keys() else { return }
        for action in PushPlanner.actions(relay: relay.base, state, known: known, reachable: reachable, now: now()) {
            do {
                try await perform(action, keys: keys, reachable: reachable)
            } catch FerryError.refused(let status, _) where status < 500 && status != 429 {
                continue   // the relay refused this one (a key it won't take): the other computers still get theirs
            } catch {
                relayRetry = now().addingTimeInterval(Self.relayBackoff)
                return
            }
        }
        relayRetry = nil
    }

    /// Throws only when the relay fails: a computer that doesn't take the subscription is tried at the next sync.
    private func perform(_ action: PushAction, keys: PushKeys, reachable: Set<URL>) async throws {
        switch action {
        case .register(let machine, let vapid):
            try await register(machine, vapid: vapid, keys: keys, reachable: reachable)
        case .subscribe(let r):
            await subscribe(r, keys: keys)
        case .check(let r):
            if try await relay.exists(r.address) {
                update(r) { $0.checked = now() }
                if reachable.contains(r.machine) { await subscribe(r, keys: keys) }
            } else {
                remove(r)
                try await register(r.machine, vapid: r.vapid, keys: keys, reachable: reachable)
            }
        case .drop(let r):
            await drop(r)
        }
    }

    private func register(_ machine: URL, vapid: String, keys: PushKeys, reachable: Set<URL>) async throws {
        guard let token = state.token else { return }
        let address = try await relay.register(token: token, env: state.env, vapid: vapid)
        let r = PushRecord(machine: machine, vapid: vapid, address: address, subscribed: false, checked: now())
        state.records.append(r)
        save()
        if reachable.contains(machine) { await subscribe(r, keys: keys) }
    }

    private func subscribe(_ r: PushRecord, keys: PushKeys) async {
        guard (try? await backend.subscribe(r.address.endpoint, keys: keys, on: r.machine)) != nil else { return }
        update(r) { $0.subscribed = true }
    }

    private func drop(_ r: PushRecord) async {
        remove(r)
        // An address at a relay the app used before is tried once and not kept: that relay is being retired, and its
        // addresses go when it does. Kept, a relay that no longer answers would hold up every sync.
        let keep = r.address.isAt(relay.base)
        if keep {
            state.pendingDeletes.append(r.address)
            save()
        }
        if (try? await relay.delete(r.address)) != nil, keep {
            state.pendingDeletes.removeAll { $0 == r.address }
            save()
        }
        try? await backend.unsubscribe(r.address.endpoint, on: r.machine)   // best effort: the deleted address is enough
    }

    private func dropAll() async {
        for r in state.records { await drop(r) }
    }

    private func update(_ r: PushRecord, _ change: (inout PushRecord) -> Void) {
        guard let i = state.records.firstIndex(where: { $0.address == r.address }) else { return }
        change(&state.records[i])
        save()
    }

    private func remove(_ r: PushRecord) {
        state.records.removeAll { $0.address == r.address }
        save()
    }

    private func save() { store.save(state) }
}
