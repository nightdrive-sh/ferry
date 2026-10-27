import Foundation
import Observation

/// Something a computer left for the phone, with the computer it is on.
public struct Received: Codable, Identifiable, Hashable, Sendable {
    public let item: Item
    public let machine: URL
    /// The computer's name: items for the phone carry no `from`, their sender is the computer itself.
    public let machineName: String
    public var id: String { Self.id(machine: machine, item: item.id) }

    public static func id(machine: URL, item: String) -> String { machine.absoluteString + "#" + item }
}

/// What a tapped notification leads to.
public enum NoticeResult: Equatable, Sendable {
    /// A text to put on the clipboard: always the whole text, never the notification's cut preview.
    case copy(String)
    case shown
    /// A long text whose computer doesn't answer: nothing is copied.
    case unreachable(name: String)
    /// No longer in the box.
    case gone
}

public enum SendState: Equatable, Sendable {
    case idle
    case sending(Double)
    case sent(to: String)
    case failed(String)
}

/// The app's state: the computers, what they hold for the phone, and sending.
@MainActor @Observable public final class FerryModel {
    public private(set) var list: MachineList
    public private(set) var status: [URL: MachineStatus] = [:]
    public private(set) var received: [Received] = []
    public private(set) var sendState: SendState = .idle
    /// A computer picked by hand, for the next send only. A pick after a failure starts over: the failure named the
    /// computer before, and Send Clipboard reads the clipboard afresh; a typed text or files wait for Try again.
    public var manual: URL? {
        didSet {
            guard manual != nil, case .failed = sendState else { return }
            sendState = canRetry ? .failed("Not sent") : .idle
        }
    }
    /// The Received row a tapped notification opened (`Received.id`), until the view lets it go.
    public private(set) var highlighted: String?
    /// Received rows whose file is on its way to the phone, for the row's spinner.
    public private(set) var loading: Set<String> = []
    /// A poll has heard from the computers (or found them unreachable) since launch: until then an empty list means
    /// "not asked yet", not "nothing there".
    public private(set) var hasPolled = false
    /// How many times this run the phone was set up with a computer, i.e. added with Add Device. It may have been
    /// forgotten before, and then the computers dropped its subscriptions: notifications subscribe again when this
    /// changes.
    public private(set) var setUps = 0

    private let backend: any FerryBackend
    private let store: MachineStore
    private let now: @Sendable () -> Date
    private let sentHold: Duration
    private var seen: Set<String>
    private var byMachine: [URL: [Received]] = [:]
    private var sentGeneration = 0
    /// What a failed typed text or file send didn't deliver, for Try again
    private var unsent: [SendPayload]?
    /// Files already on the phone, by Received.id: tap, Save and Share use one download
    private var downloaded: [String: URL] = [:]
    /// Kept files across launches; nil keeps them for this run only
    private let cache: FileCache?
    /// Downloads in flight, so a thumbnail and a fetch ahead share one
    private var inFlight: [String: Task<URL, any Error>] = [:]
    /// Fetching small files ahead after a refresh
    var prefetching: Task<Void, Never>?

    /// Files up to this size are fetched as soon as they show in the list; bigger ones (a video) when asked for.
    static let prefetchLimit: Int64 = 25_000_000
    /// How long a refresh waits before asking a computer that didn't answer again (refreshWaking)
    private let wakeRetry: Duration
    /// While a computer sleeps, how often one that answers is asked for the others: the way it is found awake again.
    static let wakeCheckEvery: TimeInterval = 10
    /// With every computer answering, how often the machine list is asked for new ones.
    static let machinesEvery: TimeInterval = 5 * 60
    /// With no computer answering to ask for the others, how often a sleeping one is asked itself.
    static let asleepEvery: TimeInterval = 120
    private var machinesAt = Date.distantPast
    private var askedAt: [URL: Date] = [:]

    static let seenKey = "seen"
    static let receivedKey = "received"

    /// A removal the computer hasn't confirmed yet (it didn't answer): the row stays gone, and it is sent again
    struct PendingRemove: Codable, Hashable { let machine: URL; let item: String }

    /// What Ferry keeps on the phone between launches: the last boxes it saw, and removals still to send.
    struct Kept: Codable {
        var boxes: [Received] = []
        var removes: [PendingRemove] = []
        /// Clear everything up to this item time (Unix seconds), per computer
        var clears: [URL: Double] = [:]
        /// Computers forgotten here that no computer has been told of yet (`api/forget`), by device name. Optional: a
        /// state kept before it existed still loads.
        var forgets: [String]?
        /// Computers forgotten here and told to one computer, by device name, with when (Unix seconds): hidden until
        /// api/machines says they are forgotten there too
        var told: [String: Double]?
    }

    private var removes: Set<PendingRemove> = []
    private var clears: [URL: Double] = [:]
    private var forgets: Set<String> = []
    private var told: [String: Date] = [:]
    /// How long a computer told is hidden without api/machines saying it is forgotten: past the minute it takes to reach
    /// the others, so it can only be a Ferry that doesn't forget
    static let toldHides: TimeInterval = 600

    public init(backend: any FerryBackend, store: MachineStore, now: @escaping @Sendable () -> Date = Date.init,
                sentHold: Duration = .seconds(2), cache: FileCache? = nil, wakeRetry: Duration = .milliseconds(1500)) {
        self.backend = backend
        self.cache = cache
        self.wakeRetry = wakeRetry
        self.store = store
        self.now = now
        self.sentHold = sentHold
        list = store.load()
        seen = Set(store.defaults.stringArray(forKey: Self.seenKey) ?? [])
        if let data = store.defaults.data(forKey: Self.receivedKey), let kept = try? JSONDecoder().decode(Kept.self, from: data) {
            let known = Set(list.machines.map(\.url))
            byMachine = Dictionary(grouping: kept.boxes.filter { known.contains($0.machine) }, by: \.machine)
            removes = Set(kept.removes)
            clears = kept.clears
            forgets = Set(kept.forgets ?? [])
            told = (kept.told ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
            rebuild()
        }
    }

    // MARK: Kept on the phone

    private func isRemoved(_ r: Received) -> Bool {
        removes.contains(PendingRemove(machine: r.machine, item: r.item.id))
            || clears[r.machine].map { r.item.time.timeIntervalSince1970 <= $0 } == true
    }

    /// A code or a password leaves the list after `Secret.keep` as it leaves the box, also while its computer sleeps
    private func rebuild() {
        let now = now()
        byMachine = byMachine.mapValues { $0.filter { !$0.item.isSecret || now.timeIntervalSince($0.item.time) < Secret.keep } }
        received = byMachine.values.joined().filter { !isRemoved($0) }.sorted { $0.item.time > $1.item.time }
    }

    private func keep() {
        let kept = Kept(boxes: Array(byMachine.values.joined()), removes: Array(removes), clears: clears,
                        forgets: forgets.isEmpty ? nil : forgets.sorted(),
                        told: told.isEmpty ? nil : told.mapValues(\.timeIntervalSince1970))
        if let data = try? JSONEncoder().encode(kept) { store.defaults.set(data, forKey: Self.receivedKey) }
    }

    /// Removals, clears and forgotten computers left while these computers didn't answer, sent now that they do. A
    /// forgotten computer needs telling only one: the others learn it from that one.
    private func sendPending(to answered: Set<URL>) async {
        for device in forgets.sorted() {
            for url in answered.sorted(by: { $0.absoluteString < $1.absoluteString }) {
                if (try? await backend.forget(device, on: url)) != nil {
                    forgets.remove(device)
                    told[device] = now()
                    break
                }
            }
        }
        for url in answered {
            if let upTo = clears[url], (try? await backend.clearReceived(on: url)) != nil {
                clears[url] = nil
                byMachine[url]?.removeAll { $0.item.time.timeIntervalSince1970 <= upTo }
            }
            for p in removes where p.machine == url {
                if (try? await backend.remove(p.item, on: url)) != nil {
                    removes.remove(p)
                    byMachine[url]?.removeAll { $0.item.id == p.item }
                }
            }
        }
    }

    public var target: URL? { TargetRule.target(list.machines, status: status, manual: manual) }

    public var isSetUp: Bool { !list.machines.isEmpty }

    /// Every listed computer and its notification key (nil until a poll gave one), for PushRegistrar.
    public var pushKeys: [URL: String?] {
        Dictionary(list.machines.map { ($0.url, status[$0.url]?.push) }, uniquingKeysWith: { a, _ in a })
    }

    public var reachableMachines: Set<URL> {
        Set(list.machines.map(\.url).filter { status[$0]?.reachable == true })
    }

    public var onlineText: String {
        if list.machines.count == 1 { return list.machines[0].name }
        let up = list.machines.filter { status[$0.url]?.reachable == true }.count
        return "\(up)/\(list.machines.count) online"
    }

    public func name(of url: URL?) -> String {
        list.machines.first { $0.url == url }?.name ?? ""
    }

    public func isNew(_ r: Received) -> Bool { !seen.contains(r.id) }

    public func markAllSeen() {
        seen = Set(received.map(\.id))   // pruned to what is still there
        store.defaults.set(Array(seen), forKey: Self.seenKey)
    }

    // MARK: Polling

    /// A refresh that gives a computer a second chance before calling it unreachable. The phone's Tailscale sleeps and
    /// wakes with the first request, and on a relayed path it drops one now and then: one miss isn't "can't reach".
    public func refreshWaking(_ only: Set<URL>? = nil) async {
        let missed = await refresh(quietFailures: true, only: only)
        guard !missed.isEmpty, !Task.isCancelled else { return }
        try? await Task.sleep(for: wakeRetry)
        guard !Task.isCancelled else { return }
        await refresh(only: missed)
    }

    /// One round of the poll while the app is on screen (every 5 s). A computer that doesn't answer isn't asked again
    /// on every round: on the phone, Tailscale's tries to reach a machine that was off jammed the tunnel to the others
    /// too (task 1394). One that answers is asked for the others instead (`api/machines` lists the ones Tailscale has
    /// online, without trying the rest), and a sleeping computer is asked as soon as it shows there. With nobody
    /// answering to ask, it is asked itself, seldom.
    public func poll() async {
        let urls = list.machines.map(\.url)
        let awake = Set(urls.filter { status[$0]?.reachable != false })
        if !awake.isEmpty { await refreshWaking(awake) }
        guard !Task.isCancelled else { return }
        let asleep = Set(urls.filter { status[$0]?.reachable == false })
        if reachableMachines.isEmpty {
            let due = asleep.filter { now().timeIntervalSince(askedAt[$0] ?? .distantPast) >= Self.asleepEvery }
            if !due.isEmpty { await refresh(only: due) }
        } else if now().timeIntervalSince(machinesAt) >= (asleep.isEmpty ? Self.machinesEvery : Self.wakeCheckEvery) {
            let woke = asleep.intersection(await refreshMachines())
            if !woke.isEmpty, !Task.isCancelled { await refresh(only: woke) }
        }
    }

    /// Every computer's box at once, or those in only. One that doesn't answer keeps the items it had: a text can still
    /// be copied. A poll cancelled midway (the app left the screen) says nothing about the computers it didn't hear
    /// from. quietFailures leaves the ones that didn't answer as they were, for refreshWaking to ask again. Returns
    /// those.
    @discardableResult
    public func refresh(quietFailures: Bool = false, only: Set<URL>? = nil) async -> Set<URL> {
        enum Answer { case box(ItemsResponse), failed, cancelled }
        let backend = backend
        let asking = list.machines.filter { only?.contains($0.url) ?? true }
        for m in asking { askedAt[m.url] = now() }
        let results = await withTaskGroup(of: (URL, Answer).self) { group in
            for m in asking {
                group.addTask {
                    do { return (m.url, .box(try await backend.items(m.url))) }
                    catch is CancellationError { return (m.url, .cancelled) }
                    catch { return (m.url, Task.isCancelled ? .cancelled : .failed) }
                }
            }
            var all: [(URL, Answer)] = []
            for await r in group { all.append(r) }
            return all
        }
        var missed = Set<URL>()
        for (url, answer) in results {
            if case .cancelled = answer { continue }
            hasPolled = true
            switch answer {
            case .cancelled:
                continue
            case .failed:
                missed.insert(url)
                if !quietFailures { status[url, default: MachineStatus()].reachable = false }
            case .box(let r):
                status[url] = MachineStatus(reachable: true, idle: r.idle, push: r.push)
                list.markSeen(url, at: now())
                byMachine[url] = r.items.filter { $0.to == .phone }.map { Received(item: $0, machine: url, machineName: r.computer) }
            }
        }
        let known = Set(list.machines.map(\.url))
        byMachine = byMachine.filter { known.contains($0.key) }
        let answered = Set(results.compactMap { url, answer in if case .box = answer { url } else { nil } })
        if !removes.isEmpty || !clears.isEmpty || !forgets.isEmpty { await sendPending(to: answered) }
        rebuild()
        keep()
        store.save(list)
        if let cache {
            cache.prune(keeping: Set(received.map(\.id)))
            if prefetching == nil { prefetching = Task { await prefetch(); prefetching = nil } }
        }
        return missed
    }

    /// The small files in the list, one after another, so they are on the phone before anyone asks.
    private func prefetch() async {
        for r in received where r.item.kind == .file && (r.item.size ?? .max) <= Self.prefetchLimit {
            if Task.isCancelled { return }
            if cache?.file(for: r) == nil { _ = try? await download(r) }
        }
    }

    /// On coming to the screen: the boxes and the machine list at once, so the list doesn't wait for `api/machines`
    /// (the server asks every other computer first).
    public func refreshAll() async {
        async let boxes: Void = refreshWaking()
        async let machines = refreshMachines()
        _ = await (boxes, machines)
    }

    /// The owner's computers, from the setup one, or any other that answers while it sleeps. Returns the ones the
    /// answering computer listed: those online now.
    @discardableResult
    public func refreshMachines(bringingBack: URL? = nil) async -> Set<URL> {
        machinesAt = now()
        let ordered = list.machines.sorted { $0.isSetup && !$1.isSetup }.filter { status[$0.url]?.reachable != false }
        var online = Set<URL>()
        for m in ordered {
            do {
                let found = try await backend.machines(m.url)
                list.merge(found.machines, at: now())
                var gone = found.forgotten
                // Set up again by hand: brought back
                if let back = bringingBack.flatMap(MachineList.device), gone.contains(back),
                   (try? await backend.unforget(back, on: m.url)) != nil {
                    gone.remove(back)
                    forgets.remove(back)
                    told[back] = nil
                }
                told = told.filter { !gone.contains($0.key) && now().timeIntervalSince($0.value) < Self.toldHides }
                // Forgotten on another device, or here and not yet known there: the answering computer lists itself all
                // the same
                let before = list.machines.map(\.url)
                list.forget(devices: gone.union(forgets).union(told.keys))
                for url in before where !list.machines.contains(where: { $0.url == url }) { drop(url) }
                online = Set(found.machines.map { MachineList.normalized($0.url) }).intersection(list.machines.map(\.url))
                keep()
                break
            } catch {
                if error is CancellationError || Task.isCancelled { return [] }
                status[m.url, default: MachineStatus()].reachable = false
            }
        }
        list.forgetStale(now: now())
        store.save(list)
        return online
    }

    /// How long setup waits for a computer whose tries run out of time. One just set up gets its HTTPS certificate in
    /// its first half minute or so (tailscaled fetches it when Ferry publishes itself, about 37 s), and until then its
    /// address doesn't answer: the phone may well scan its QR code sooner.
    public static let setupPatience: Duration = .seconds(60)

    /// A computer given by QR code or name: it must answer before it is kept. The first one, or one added with
    /// `asSetup`, becomes the setup computer; Settings › Add a Computer adds one beside it. While a try runs out of time,
    /// it is asked again until `patience` has passed (`waiting` is told once, when the first one does); any other
    /// failure ends it at once, and so does cancelling.
    public func setUp(_ url: URL, asSetup: Bool = true, patience: Duration = .zero, retryAfter: Duration = .seconds(1),
                      waiting: () -> Void = {}) async throws {
        let url = MachineList.normalized(url)
        let clock = ContinuousClock()
        let end = clock.now + patience
        var tries = 0
        let name: String
        while true {
            do {
                name = try await backend.ping(url)
                break
            } catch FerryError.unreachable(_, timedOut: true) where clock.now + retryAfter < end {
                tries += 1
                if tries == 1 { waiting() }
                try await Task.sleep(for: retryAfter)
            }
        }
        list.add(url, name: name, at: now(), asSetup: asSetup)
        status[url] = MachineStatus(reachable: true)
        if let device = MachineList.device(url) {   // forgotten here before: added again, it isn't
            forgets.remove(device)
            told[device] = nil
            keep()
        }
        store.save(list)
        let online = await refreshMachines(bringingBack: url)
        // Added with Add Device: the phone brings itself back where it was forgotten (docs/protocol.md › Forgetting a
        // device). Every computer that answers is told, not only the one set up, which may be a Ferry from before (it
        // answers 400). Best effort: one asleep learns it from the others' lists.
        let backend = backend
        await withTaskGroup(of: Void.self) { group in
            for machine in online.union([url]) {
                group.addTask { try? await backend.unforgetSelf(on: machine) }
            }
        }
        setUps += 1
        await refresh()
    }

    /// Settings › Forget: the computer, what it held and what was known of it, here and on the owner's other devices
    /// (docs/protocol.md › Forgetting a device). One computer is told (`api/forget`): another that answers, else the
    /// forgotten one itself, else the first to answer a later refresh.
    public func forget(_ url: URL) async {
        let ask = list.machines.sorted { $0.isSetup && !$1.isSetup }
            .filter { $0.url != url && status[$0.url]?.reachable != false }.map(\.url) + [url]
        list.forget(url)
        drop(url)
        store.save(list)
        guard let device = MachineList.device(url) else { return keep() }
        forgets.insert(device)
        keep()
        for machine in ask where (try? await backend.forget(device, on: machine)) != nil {
            forgets.remove(device)
            told[device] = now()
            keep()
            return
        }
    }

    /// What was known of a computer no longer in the list
    private func drop(_ url: URL) {
        status[url] = nil
        byMachine[url] = nil
        clears[url] = nil
        removes = removes.filter { $0.machine != url }
        if manual == url { manual = nil }
        for r in received where r.machine == url { dropDownload(r.id) }
        received.removeAll { $0.machine == url }
    }

    /// Settings › Use for Setup: where the others are found from, and the target on a tie.
    public func makeSetup(_ url: URL) {
        list.makeSetup(url)
        store.save(list)
    }

    // MARK: Sending

    /// Sends at once to the current target, however old the last poll (Jari's choice: the name in "Sent to …" shows a
    /// wrong one). nil is an empty clipboard.
    public func send(_ payload: SendPayload?) async {
        guard let payload else { return sendState = .failed(FerryError.emptyClipboard.message) }
        await send([payload])
    }

    /// Several things (photos picked together) to one computer: a hand pick holds for the whole batch. The first failure
    /// stops it.
    public func send(_ payloads: [SendPayload]) async {
        guard !payloads.isEmpty else { return }
        unsent = nil
        guard let to = target else { return sendState = .failed(FerryError.noMachine.message) }
        let name = name(of: to)
        var done = 0
        do {
            for (i, payload) in payloads.enumerated() {
                done = i
                let share = 1 / Double(payloads.count)
                sendState = .sending(Double(i) * share)
                try await backend.send(payload, to: to) { [weak self] p in
                    Task { @MainActor in
                        if case .sending = self?.sendState { self?.sendState = .sending((Double(i) + p) * share) }
                    }
                }
            }
            manual = nil
            sendState = .sent(to: name)
            sentGeneration += 1
            let generation = sentGeneration
            Task { [weak self, sentHold] in
                try? await Task.sleep(for: sentHold)
                if let self, self.sentGeneration == generation, case .sent = self.sendState { self.sendState = .idle }
            }
        } catch {
            keepUnsent(Array(payloads[done...]))
            fail(error, to: to, name: name)
        }
    }

    /// Try again sends what didn't arrive. A clipboard send isn't kept: Try again reads the clipboard afresh, so a
    /// one-time code copied meanwhile goes instead of the expired one.
    public var canRetry: Bool { unsent != nil }

    public func retry() async {
        guard let unsent else { return }
        await send(unsent)
    }

    private func keepUnsent(_ payloads: [SendPayload]) {
        let isClip = payloads.contains {
            switch $0 { case .text(_, let clip), .file(_, _, _, let clip): clip }
        }
        unsent = isClip ? nil : payloads
    }

    private func fail(_ error: any Error, to: URL, name: String) {
        switch error {
        case FerryError.unreachable:
            status[to, default: MachineStatus()].reachable = false
            sendState = .failed(FerryError.unreachable(machine: name).message)
        case let e as FerryError:
            sendState = .failed(e.message)
        default:
            sendState = .failed(error.localizedDescription)
        }
    }

    // MARK: Notifications

    /// A tapped notification: finds its item (asking the computers again when the last poll hasn't seen it yet) and
    /// highlights it; a text comes back to be copied, from the notification when it carried the whole text, otherwise
    /// from the computer. machine is nil when the notification came through an address the app no longer remembers
    /// (it was reinstalled, or its state reset): the item is then looked for by its id on every computer.
    public func openNotice(machine: URL?, id: String?, kind: Item.Kind?, text: String?) async -> NoticeResult {
        guard let id else { return .shown }
        func find() -> Received? {
            received.first { $0.item.id == id && (machine == nil || $0.machine == machine) }
        }
        if find() == nil { await refreshWaking() }
        let found = find()
        if let found { highlighted = found.id }
        // A code or a password leaves the box once copied: the computer hears of it after the copy, not before. One
        // that left already (15 minutes, or copied) isn't copied from its notification (docs/protocol.md › Codes and
        // passwords).
        if kind == .text, let text, !Secret.looksLike(text) || found != nil {
            if let found { Task { await copied(found) } }
            return .copy(text)
        }
        if let found, found.item.kind == .text {
            Task { await copied(found) }
            return .copy(found.item.text ?? "")
        }
        if found != nil { return .shown }
        if let machine, status[machine]?.reachable == false { return .unreachable(name: name(of: machine)) }
        return .gone
    }

    public func clearHighlight() { highlighted = nil }

    // MARK: The list

    /// A text was copied: a code or a password leaves the box then (docs/protocol.md › Codes and passwords).
    public func copied(_ r: Received) async {
        if r.item.isSecret { await remove(r) }
    }

    /// Gone from the list at once; the computer is told now, or when it answers again.
    public func remove(_ r: Received) async {
        let pending = PendingRemove(machine: r.machine, item: r.item.id)
        removes.insert(pending)
        rebuild()
        dropDownload(r.id)
        keep()
        guard (try? await backend.remove(r.item.id, on: r.machine)) != nil else { return }
        removes.remove(pending)
        byMachine[r.machine]?.removeAll { $0.id == r.id }
        keep()
    }

    /// Everything empties at once; a computer that doesn't answer is cleared when it does, and only of what was
    /// there at the tap: what it sends afterwards shows.
    public func clearReceived() async {
        for (url, rows) in byMachine {
            if let newest = rows.map({ $0.item.time.timeIntervalSince1970 }).max() { clears[url] = max(clears[url] ?? 0, newest) }
        }
        for r in received { dropDownload(r.id) }
        rebuild()
        keep()
        let backend = backend, machines = list.machines.map(\.url)
        let cleared = await withTaskGroup(of: URL?.self) { group in
            for url in machines {
                group.addTask { (try? await backend.clearReceived(on: url)) != nil ? url : nil }
            }
            var done = Set<URL>()
            for await u in group { if let u { done.insert(u) } }
            return done
        }
        for url in cleared {
            clears[url] = nil
            byMachine[url] = []
        }
        keep()
    }

    public func download(_ r: Received) async throws -> URL {
        if let file = downloaded[r.id], FileManager.default.fileExists(atPath: file.path()) { return file }
        if let file = cache?.file(for: r) {
            downloaded[r.id] = file
            return file
        }
        let task: Task<URL, any Error>
        if let running = inFlight[r.id] {
            task = running
        } else {
            let backend = backend, cache = cache
            task = Task {
                let file = try await backend.download(r.item, from: r.machine)
                return try cache?.store(file, for: r) ?? file
            }
            inFlight[r.id] = task
            loading.insert(r.id)
        }
        // Whoever wakes first clears it: the one who started it and one who joined both await the same task
        defer {
            inFlight[r.id] = nil
            loading.remove(r.id)
        }
        let file = try await task.value
        downloaded[r.id] = file
        return file
    }

    /// A downloaded file goes with its item (HTTPBackend and FileCache put each in a folder of its own).
    private func dropDownload(_ id: String) {
        cache?.remove(id)
        guard let file = downloaded.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
