import Foundation

/// A send to a computer that was asleep or off, kept on the phone until it is back (docs/protocol.md › Clients ›
/// Sends that wait). Nothing waits anywhere else: the push relay never sees content.
public struct QueuedSend: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let time: Date
    public let machine: URL
    public let machineName: String
    public let kind: Item.Kind
    public let text: String?
    /// A file's name, type and size; `stored` is its copy's name in the send's folder
    public let name: String?
    public let type: String?
    public let size: Int64?
    let stored: String?

    /// Seconds a send waits for its computer (Jari, 3.11.: three days, so a weekend is covered)
    public static let wait: TimeInterval = 3 * 86400

    public var isSecret: Bool { kind == .text && Secret.looksLike(text ?? "") }

    /// When it is dropped unclaimed: a code or a password after Secret.keep, as the box drops it
    public var until: Date { time.addingTimeInterval(isSecret ? Secret.keep : Self.wait) }

    /// The send in a few words, for its row and its notification
    public var what: String {
        if kind == .file { return name ?? "file" }
        return isSecret ? Secret.named : (text ?? "").components(separatedBy: .newlines).joined(separator: " ")
    }
}

/// The phone's waiting sends, in the App Group's container, so the share extension adds to them and the app sends
/// them. Each send is a folder of its own (`<id>/send.json`, a file's copy beside it): two processes adding at once
/// never write the same file, and removing one is removing its folder.
public struct SendQueue: Sendable {
    public let folder: URL
    private let now: @Sendable () -> Date

    public init(folder: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.folder = folder
        self.now = now
    }

    public static func appGroup(_ group: String) -> SendQueue? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            .map { SendQueue(folder: $0.appending(path: "Waiting")) }
    }

    /// Keeps one payload for the computer at machine. The clipboard is sent without `clip` once it waited (on the other
    /// clipboard later, it would replace whatever was copied there since). A file is copied, so the picked or shared
    /// one may go meanwhile.
    @discardableResult
    public func add(_ payload: SendPayload, to machine: URL, name machineName: String) throws -> QueuedSend {
        let id = UUID().uuidString.lowercased()
        let dir = folder.appending(path: id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let send: QueuedSend
        switch payload {
        case .text(let text, _):
            send = QueuedSend(id: id, time: now(), machine: machine, machineName: machineName, kind: .text, text: text,
                              name: nil, type: nil, size: nil, stored: nil)
        case .file(let url, let name, let type, _):
            let stored = Self.storedName(name)
            do {
                try fm.copyItem(at: url, to: dir.appending(path: stored))
            } catch {
                try? fm.removeItem(at: dir)
                throw error
            }
            let size = (try? dir.appending(path: stored).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            send = QueuedSend(id: id, time: now(), machine: machine, machineName: machineName, kind: .file, text: nil,
                              name: name, type: type, size: size, stored: stored)
        }
        // Written last: a folder without it is a send still being made, which list() leaves alone
        try JSONEncoder().encode(send).write(to: dir.appending(path: "send.json"), options: .atomic)
        return send
    }

    /// Newest first, without the expired ones, whose folders go
    public func list() -> [QueuedSend] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var out: [QueuedSend] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appending(path: "send.json")),
                  let send = try? JSONDecoder().decode(QueuedSend.self, from: data) else { continue }
            if now() >= send.until || (send.kind == .file && file(of: send).map { !fm.fileExists(atPath: $0.path) } != false) {
                try? fm.removeItem(at: dir)
                continue
            }
            out.append(send)
        }
        return out.sorted { $0.time > $1.time }
    }

    /// Delivered, refused or cancelled
    public func remove(_ id: String) {
        guard !id.isEmpty, !id.contains("/") else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: id))
    }

    /// What goes when its computer is back: never with `clip`
    public func payload(of send: QueuedSend) -> SendPayload? {
        switch send.kind {
        case .text: return send.text.map { .text($0, clip: false) }
        case .file:
            guard let url = file(of: send) else { return nil }
            return .file(url, name: send.name ?? url.lastPathComponent, type: send.type ?? "application/octet-stream",
                         clip: false)
        }
    }

    func file(of send: QueuedSend) -> URL? {
        send.stored.map { folder.appending(path: send.id).appending(path: $0) }
    }

    /// The copy's name on disk: the file's own, without a path, never send.json
    static func storedName(_ name: String) -> String {
        let base = name.split(separator: "/").last.map(String.init) ?? ""
        return base.isEmpty || base == "send.json" || base.hasPrefix(".") ? "file" : base
    }
}

extension FerryError {
    /// The computer said nothing (asleep, off, Tailscale down), or tailscale serve answered for it with 502–504 while
    /// its Ferry isn't up yet: a send to it waits rather than fails
    public var isNoAnswer: Bool {
        switch self {
        case .unreachable: true
        case .refused(let status, _): (502...504).contains(status)
        default: false
        }
    }
}

/// How a waiting send went when its computer answered again.
public enum QueuedOutcome: Equatable, Sendable {
    case delivered
    /// The computer answered no (no room, too big): it is dropped, with what it said
    case refused(String)
}

extension SendQueue {
    /// The waiting sends for the computers in `answered`, oldest first; each that goes or is refused leaves the queue.
    /// A computer that stops answering midway keeps the rest for next time.
    public func deliver(to answered: Set<URL>, with backend: any FerryBackend) async -> [(QueuedSend, QueuedOutcome)] {
        var done: [(QueuedSend, QueuedOutcome)] = []
        var silent = Set<URL>()
        for send in list().reversed() where answered.contains(send.machine) && !silent.contains(send.machine) {
            guard let payload = payload(of: send) else { continue }
            do {
                try await backend.send(payload, to: send.machine) { _ in }
                remove(send.id)
                done.append((send, .delivered))
            } catch let e as FerryError where !e.isNoAnswer {
                remove(send.id)
                done.append((send, .refused(e.message)))
            } catch {
                silent.insert(send.machine)
            }
        }
        return done
    }
}
