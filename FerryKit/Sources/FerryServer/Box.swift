import FerryKit
import Foundation

/// JSON as the API writes it: the box's items and the machine list go out as objects whose keys vary.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
}

/// One thing in the box (docs/protocol.md › Items), with where its file is on this computer.
public struct BoxItem: Codable, Sendable, Equatable {
    public var id: String
    /// "phone": left for a device. "computer": received from one.
    public var to: String
    /// "text" or "file"
    public var kind: String
    /// Unix seconds
    public var time: Double
    public var text: String?
    public var name: String?
    public var size: Int64?
    public var type: String?
    /// The sending device's tailnet name, on items to "computer"
    public var from: String?
    /// The one device an item to "phone" is for; nil for any
    public var forDevice: String?
    public var seen: Bool?
    /// The file on this computer: in Downloads for one received, under the state's files/ for one left for a device.
    /// Never sent.
    public var path: String?

    enum CodingKeys: String, CodingKey {
        case id, to, kind, time, text, name, size, type, from, forDevice = "for", seen, path
    }

    public init(id: String, to: String, kind: String, time: Double, text: String? = nil, name: String? = nil,
                size: Int64? = nil, type: String? = nil, from: String? = nil, for device: String? = nil,
                seen: Bool? = nil, path: String? = nil) {
        self.id = id
        self.to = to
        self.kind = kind
        self.time = time
        self.text = text
        self.name = name
        self.size = size
        self.type = type
        self.from = from
        self.forDevice = device
        self.seen = seen
        self.path = path
    }

    /// A code or a password (docs/protocol.md › Codes and passwords)
    public var isSecret: Bool {
        kind == "text" && Secret.looksLike(text ?? "")
    }

    /// The item as the API lists it: bin/ferry's `public()`, everything but the path
    public var wire: [String: JSONValue] {
        var d: [String: JSONValue] = ["id": .string(id), "to": .string(to), "kind": .string(kind), "time": .double(time)]
        if let text { d["text"] = .string(text) }
        if let name { d["name"] = .string(name) }
        if let size { d["size"] = .int(size) }
        if let type { d["type"] = .string(type) }
        if let from { d["from"] = .string(from) }
        if let forDevice { d["for"] = .string(forDevice) }
        if let seen { d["seen"] = .bool(seen) }
        if isSecret { d["secret"] = .bool(true) }
        return d
    }
}

/// The box: items both ways, kept `keepDays` days (a code or a password 15 minutes, or until it is copied), saved in
/// the state folder's items.json after every change.
public actor Box {
    private let state: URL
    private let keep: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private var all: [BoxItem]
    /// Something from a device landed: the menu's count follows it without polling
    private let changed: @Sendable () -> Void

    public init(state: URL, keepDays: Int, clock: @escaping @Sendable () -> TimeInterval, changed: @escaping @Sendable () -> Void = {}) {
        self.state = state
        self.changed = changed
        keep = TimeInterval(keepDays) * 86400
        self.clock = clock
        struct Saved: Decodable { var items: [BoxItem]? }
        all = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: state.appending(path: "items.json"))))?.items ?? []
    }

    public static func newID() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// The items, oldest first, after pruning
    public func items() -> [BoxItem] {
        prune()
        return all
    }

    /// What the page or app on device lists: what was sent here, and what waits for it or for any device
    /// (bin/ferry's `for_device()`)
    public func listed(for device: String) -> [BoxItem] {
        items().filter { $0.to != "phone" || $0.forDevice == nil || $0.forDevice == device }
    }

    public func find(id: String) -> BoxItem? {
        items().first { $0.id == id }
    }

    public func append(_ items: [BoxItem]) {
        all += items
        prune(saving: true)
        if items.contains(where: { $0.to == "computer" }) { changed() }
    }

    public func remove(id: String) {
        let received = all.contains { $0.id == id && $0.to == "computer" }
        for it in all where it.id == id { dropFile(it) }
        all.removeAll { $0.id == id }
        save()
        if received { changed() }
    }

    /// A text was copied on this computer: a code or a password leaves the box then (docs/protocol.md › Codes and
    /// passwords)
    public func copied(id: String) {
        if all.contains(where: { $0.id == id && $0.isSecret }) { remove(id: id) }
    }

    public func clear(to direction: String) {
        for it in all where it.to == direction { dropFile(it) }
        all.removeAll { $0.to == direction }
        save()
        if direction == "computer" { changed() }
    }

    /// Writes the box only when something was unseen: the popover asks every few seconds while it is open
    public func markSeen() {
        let unseen = all.indices.filter { all[$0].to == "computer" && all[$0].seen != true }
        guard !unseen.isEmpty else { return }
        for i in unseen { all[i].seen = true }
        save()
    }

    /// A file left for a device (device "" for any): a hard link into files/<id>/, so a big video isn't copied, or a
    /// copy when the file is on another volume. The original stays the user's.
    public func leaveFile(_ src: URL, for device: String) throws -> BoxItem {
        let fm = FileManager.default
        let name = FileNames.safe(src.lastPathComponent)
        let id = Self.newID()
        let folder = state.appending(path: "files/\(id)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dest = folder.appending(path: name)
        do { try fm.linkItem(at: src, to: dest) } catch { try fm.copyItem(at: src, to: dest) }
        let size = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let item = BoxItem(id: id, to: "phone", kind: "file", time: clock(), name: name, size: size,
                           type: MIME.type(forName: name), for: device.isEmpty ? nil : device, path: dest.path)
        append([item])
        return item
    }

    /// Drops old items, and those whose file is gone; a file left for a device goes with its item.
    public func prune() {
        prune(saving: false)
    }

    /// A code or a password is kept `Secret.keep`, everything else `keepDays`
    private func alive(_ it: BoxItem, now: TimeInterval) -> Bool {
        now - it.time < (it.isSecret ? Secret.keep : keep)
            && (it.kind != "file" || FileManager.default.fileExists(atPath: it.path ?? ""))
    }

    private func prune(saving: Bool) {
        let now = clock()
        let dead = all.filter { !alive($0, now: now) }
        for it in dead { dropFile(it) }
        all.removeAll { !alive($0, now: now) }
        if saving || !dead.isEmpty { save() }
        if dead.contains(where: { $0.to == "computer" }) { changed() }
    }

    /// The copy left for a device. A file received from one stays in Downloads.
    private func dropFile(_ it: BoxItem) {
        guard it.kind == "file", it.to == "phone", let path = it.path else { return }
        try? FileManager.default.removeItem(at: URL(filePath: path).deletingLastPathComponent())
    }

    private func save() {
        struct Saved: Encodable { var items: [BoxItem] }
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        try? encoder.encode(Saved(items: all)).write(to: state.appending(path: "items.json"), options: .atomic)
    }
}
