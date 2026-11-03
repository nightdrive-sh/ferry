import FerryKit
import Foundation

/// A send to another computer that was asleep or off, kept on this Mac until that computer is back
/// (docs/protocol.md › Clients › Sends that wait). bin/ferry's outbox.py keeps the same.
public struct WaitingSend: Codable, Sendable, Equatable, Identifiable {
    public struct File: Codable, Sendable, Equatable {
        /// Its copy's name in the send's own folder (outbox/<id>/)
        public var stored: String
        /// The name it is sent with
        public var name: String
        public var size: Int64
        public var type: String
    }

    public var id: String
    public var time: TimeInterval
    /// The computer's short tailnet name, and the name it was shown with
    public var device: String
    public var name: String
    public var kind: String
    public var text: String?
    public var files: [File]

    public var isSecret: Bool { kind == "text" && Secret.looksLike(text ?? "") }

    /// When it is dropped unclaimed
    public var until: TimeInterval { time + (isSecret ? Secret.keep : Outbox.wait) }

    /// The send in a few words, as "Sent" names one
    public var what: String {
        if kind == "text" { return isSecret ? Secret.named : (text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ") }
        return files.count == 1 ? files[0].name : "\(files.count) files"
    }

    public var size: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// The waiting sends, in state/outbox.json, their files (a hard link, else a copy) in state/outbox/<id>/ so a file
/// moved or deleted meanwhile still goes.
public actor Outbox {
    /// Seconds a send waits for its computer (Jari, 3.11.: three days, so a weekend is covered)
    public static let wait: TimeInterval = 3 * 86400

    private let state: URL
    private let clock: @Sendable () -> TimeInterval
    private var sends: [WaitingSend]

    init(state: URL, clock: @escaping @Sendable () -> TimeInterval) {
        self.state = state
        self.clock = clock
        sends = StateFile.load([WaitingSend].self, state.appending(path: "outbox.json")) ?? []
    }

    private var folder: URL { state.appending(path: "outbox") }

    func url(of file: WaitingSend.File, in send: WaitingSend) -> URL {
        folder.appending(path: send.id).appending(path: file.stored)
    }

    /// Oldest first, the expired and those whose files went gone
    public func list() -> [WaitingSend] {
        prune()
        return sends
    }

    func add(text: String, for device: Device) -> WaitingSend {
        let send = WaitingSend(id: Box.newID(), time: clock(), device: device.id, name: device.name, kind: "text",
                               text: text, files: [])
        sends.append(send)
        save()
        return send
    }

    /// nil when a file couldn't be kept (gone, or the disk full)
    func add(files: [URL], for device: Device) -> WaitingSend? {
        var send = WaitingSend(id: Box.newID(), time: clock(), device: device.id, name: device.name, kind: "file",
                               text: nil, files: [])
        let fm = FileManager.default
        let dir = folder.appending(path: send.id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for src in files {
            let dest = FileNames.unique(dir.appending(path: FileNames.safe(src.lastPathComponent)))
            do {
                do { try fm.linkItem(at: src, to: dest) } catch { try fm.copyItem(at: src, to: dest) }
            } catch {
                try? fm.removeItem(at: dir)
                return nil
            }
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            send.files.append(.init(stored: dest.lastPathComponent, name: src.lastPathComponent, size: size,
                                    type: MIME.type(forName: src.lastPathComponent)))
        }
        sends.append(send)
        save()
        return send
    }

    /// A file the computer took: a send that breaks off goes on from the next one
    func crossOff(_ file: WaitingSend.File, of id: String) {
        guard let i = sends.firstIndex(where: { $0.id == id }) else { return }
        sends[i].files.removeAll { $0 == file }
        try? FileManager.default.removeItem(at: url(of: file, in: sends[i]))
        save()
    }

    /// Delivered, refused or cancelled: whether there was one
    @discardableResult
    public func remove(_ id: String) -> Bool {
        guard let i = sends.firstIndex(where: { $0.id == id }) else { return false }
        drop(sends.remove(at: i))
        save()
        return true
    }

    public func clear() {
        sends.forEach(drop)
        sends = []
        save()
    }

    /// Nothing is sent to a forgotten computer
    func drop(devices: Set<String>) {
        let gone = sends.filter { devices.contains($0.device) }
        guard !gone.isEmpty else { return }
        gone.forEach(drop)
        sends.removeAll { devices.contains($0.device) }
        save()
    }

    private func prune() {
        let now = clock()
        let stale = sends.filter { s in
            now >= s.until || s.files.contains { !FileManager.default.fileExists(atPath: url(of: $0, in: s).path) }
        }
        guard !stale.isEmpty else { return }
        stale.forEach(drop)
        sends.removeAll { s in stale.contains { $0.id == s.id } }
        save()
    }

    private func drop(_ send: WaitingSend) {
        try? FileManager.default.removeItem(at: folder.appending(path: send.id))
    }

    private func save() {
        StateFile.save(sends, state.appending(path: "outbox.json"))
    }
}
