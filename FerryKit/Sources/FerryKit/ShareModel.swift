import Foundation
import Observation
import Synchronization

/// Sends a share's files: the share extension's background uploader, which goes on after the extension is ended.
public protocol FileSender: Sendable {
    /// All of `files` to `machine` at once; `progress` gets 0…1 over all of them, `delivered` each file the computer
    /// took. Throws `FerryError.unreachable(machine:)` when nothing moves for 8 s.
    func send(_ files: [Upload], to machine: URL, machineName: String,
              progress: @escaping @Sendable (Double) -> Void, delivered: @escaping @Sendable (Upload) -> Void) async throws
}

/// One file of a share, on its way to `api/upload` (never with `clip`: a share isn't the clipboard).
public struct Upload: Codable, Hashable, Sendable {
    public let file: URL
    public let name: String
    public let type: String

    public init(file: URL, name: String, type: String) {
        self.file = file
        self.name = name
        self.type = type
    }
}

/// What a computer said when the share sheet asked it.
public enum Reply: Equatable, Sendable {
    case asking
    case answered(idle: Int?)
    case unreachable
}

/// A computer in the share view's list.
public struct ShareRow: Identifiable, Equatable, Sendable {
    public let machine: KnownMachine
    public var reply: Reply
    public var id: URL { machine.url }

    /// "asking…", then as in the app's Send to menu: "in use", "used 20 min ago", "can't reach".
    public var subtitle: String {
        reply == .asking ? "asking…" : TargetRule.usedLabel(status)
    }

    var status: MachineStatus? {
        switch reply {
        case .asking: nil
        case .answered(let idle): MachineStatus(reachable: true, idle: idle)
        case .unreachable: MachineStatus(reachable: false)
        }
    }
}

public enum ShareState: Equatable, Sendable {
    case noMachine
    case nothingToSend
    /// No computer has answered yet
    case asking
    /// At least one can be tapped
    case choosing
    case sending(Double)
    case sent(to: String)
    case failed(String)
}

/// The share sheet: which computer a share goes to, and when (the phase 3 design › How it behaves). No question when
/// there is no choice: one computer known, or only one that answers.
@MainActor @Observable public final class ShareModel {
    public private(set) var rows: [ShareRow]
    public private(set) var state: ShareState = .asking
    /// What the share carries, once loaded (a big video takes a while to copy out of Photos): nil until then
    public private(set) var payloads: [SendPayload]?

    private let machines: [KnownMachine]
    private let load: @Sendable () async -> [SendPayload]
    private let ask: any FerryBackend
    private let send: any FerryBackend
    private let files: any FileSender
    /// Rows keep their place shortly after the first answer, so a late answer never moves a row from under a finger
    private var frozen = false
    /// How long after the first answer the rows still sort: computers that are awake answer within moments of each
    /// other, and no one aims a tap that fast, so the one in use goes first whichever answered first
    private let settle: Duration
    private var settling: Task<Void, Never>?
    /// Where the last send went, for Try again
    private var lastTarget: KnownMachine?
    /// What the last send didn't deliver: Try again sends only that
    private var unsent: [SendPayload]?

    public convenience init(machines: [KnownMachine], payloads: [SendPayload], ask: any FerryBackend,
                            send: any FerryBackend, files: any FileSender, settle: Duration = .milliseconds(400)) {
        self.init(machines: machines, load: { payloads }, ask: ask, send: send, files: files, settle: settle)
    }

    /// The list shows at once, with every computer "asking…", while `load` gets the share ready.
    public init(machines: [KnownMachine], load: @escaping @Sendable () async -> [SendPayload], ask: any FerryBackend,
                send: any FerryBackend, files: any FileSender, settle: Duration = .milliseconds(400)) {
        self.machines = machines
        self.load = load
        self.settle = settle
        self.ask = ask
        self.send = send
        self.files = files
        rows = TargetRule.order(machines, status: [:]).map { ShareRow(machine: $0, reply: .asking) }
    }

    public var sendsFiles: Bool { !uploads.isEmpty }

    private var uploads: [Upload] { Self.uploads(payloads ?? []) }

    private static func uploads(_ p: [SendPayload]) -> [Upload] {
        p.compactMap { if case .file(let url, let name, let type, _) = $0 { Upload(file: url, name: name, type: type) } else { nil } }
    }

    public func start() async {
        lastTarget = nil
        unsent = nil
        guard !machines.isEmpty else { return state = .noMachine }
        if payloads == nil { payloads = await load() }
        guard payloads?.isEmpty == false else { return state = .nothingToSend }
        // A text to the only computer goes at once, as Send Clipboard does. A file asks first: a background upload to
        // a computer that doesn't answer would wait for it instead of failing
        if machines.count == 1, !sendsFiles { return await sendAll(to: machines[0]) }
        rows = TargetRule.order(machines, status: [:]).map { ShareRow(machine: $0, reply: .asking) }
        frozen = false
        settling?.cancel()
        settling = nil
        state = .asking
        let ask = ask
        await withTaskGroup(of: (URL, Reply).self) { group in
            for m in machines {
                group.addTask { (m.url, await Self.ask(ask, m.url)) }
            }
            for await (url, reply) in group { await record(reply, for: url) }
        }
    }

    /// A tap on a row: only one that answered, and only while nothing is on its way.
    public func pick(_ machine: URL) async {
        guard isDeciding, let row = rows.first(where: { $0.id == machine }), case .answered = row.reply else { return }
        await sendAll(to: row.machine)
    }

    /// After a failure: the same computer again when a send failed, otherwise every computer asked again.
    public func retry() async {
        guard case .failed = state else { return }
        if let lastTarget { await sendAll(to: lastTarget) } else { await start() }
    }

    // MARK: -

    private var isDeciding: Bool { state == .asking || state == .choosing }

    /// The phone's Tailscale drops a first request now and then: a miss gets a second ask before it counts.
    private nonisolated static func ask(_ backend: any FerryBackend, _ url: URL) async -> Reply {
        for _ in 0..<2 {
            if let box = try? await backend.items(url) { return .answered(idle: box.idle) }
        }
        return .unreachable
    }

    private func record(_ reply: Reply, for url: URL) async {
        guard let i = rows.firstIndex(where: { $0.id == url }) else { return }
        rows[i].reply = reply
        if !frozen, case .answered = reply {
            let status = Dictionary(uniqueKeysWithValues: rows.compactMap { r in r.status.map { (r.id, $0) } })
            let order = TargetRule.order(rows.map(\.machine), status: status)
            rows = order.compactMap { m in rows.first { $0.id == m.url } }
            if settling == nil {
                settling = Task { [weak self, settle] in
                    try? await Task.sleep(for: settle)
                    if !Task.isCancelled { self?.frozen = true }
                }
            }
        }
        guard isDeciding else { return }   // a pick went out first: late answers change only the subtitles
        let answered = rows.filter { if case .answered = $0.reply { true } else { false } }
        guard rows.allSatisfy({ $0.reply != .asking }) else {
            if !answered.isEmpty { state = .choosing }
            return
        }
        switch answered.count {
        case 0:
            state = .failed(machines.count == 1 ? FerryError.unreachable(machine: machines[0].name).message
                                                : "Can't reach your computers. Is Tailscale on?")
        case 1:
            await sendAll(to: answered[0].machine)
        default:
            state = .choosing
        }
    }

    private func sendAll(to machine: KnownMachine) async {
        lastTarget = machine
        state = .sending(0)
        let left = unsent ?? payloads ?? []
        unsent = left
        let texts = left.filter { if case .text = $0 { true } else { false } }, uploads = Self.uploads(left)
        let total = Double(texts.count + uploads.count)
        let arrived = Mutex<Set<URL>>([])
        // Files the computer took stay out of Try again, whether the rest arrived or not
        defer {
            let arrived = arrived.withLock { $0 }
            unsent?.removeAll { if case .file(let url, _, _, _) = $0 { arrived.contains(url) } else { false } }
        }
        do {
            for (i, t) in texts.enumerated() {
                try await send.send(t, to: machine.url) { _ in }
                unsent?.removeAll { $0 == t }
                state = .sending(Double(i + 1) / total)
            }
            if !uploads.isEmpty {
                let done = Double(texts.count), share = Double(uploads.count)
                try await files.send(uploads, to: machine.url, machineName: machine.name, progress: { [weak self] p in
                    Task { @MainActor in
                        if case .sending = self?.state { self?.state = .sending((done + p * share) / total) }
                    }
                }, delivered: { u in arrived.withLock { _ = $0.insert(u.file) } })
            }
            unsent = nil
            state = .sent(to: machine.name)
        } catch FerryError.unreachable {
            state = .failed(FerryError.unreachable(machine: machine.name).message)
        } catch let e as FerryError {
            state = .failed(e.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
