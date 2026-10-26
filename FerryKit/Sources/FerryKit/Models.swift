import Foundation

/// One thing in a computer's box, as `api/items` lists it (docs/protocol.md › Items).
public struct Item: Codable, Hashable, Identifiable, Sendable {
    public enum Direction: String, Codable, Sendable { case phone, computer }
    public enum Kind: String, Codable, Sendable { case text, file }

    public let id: String
    public let to: Direction
    public let kind: Kind
    public let time: Date
    public let text: String?
    public let name: String?
    public let size: Int64?
    public let type: String?
    /// The sending device's tailnet name. Only items from a phone have it: what a computer leaves for the phone doesn't.
    public let from: String?
    public let seen: Bool?

    /// A text that is one web address and nothing else, which the list offers to open.
    public var isLink: Bool {
        kind == .text && WebLink.url(in: text ?? "") != nil
    }

    /// A code or a password (docs/protocol.md › Codes and passwords): gone from the box once copied, or after
    /// `Secret.keep`. The rule is the same as the computer's, so its `secret` mark isn't read.
    public var isSecret: Bool {
        kind == .text && Secret.looksLike(text ?? "")
    }

    enum CodingKeys: String, CodingKey { case id, to, kind, time, text, name, size, type, from, seen }

    /// An item made on the phone rather than read from a computer (the demo's pretend computers).
    public init(id: String, to: Direction, kind: Kind, time: Date, text: String? = nil, name: String? = nil,
                size: Int64? = nil, type: String? = nil, from: String? = nil, seen: Bool? = nil) {
        self.id = id
        self.to = to
        self.kind = kind
        self.time = time
        self.text = text
        self.name = name
        self.size = size
        self.type = type
        self.from = from
        self.seen = seen
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        to = try c.decode(Direction.self, forKey: .to)
        kind = try c.decode(Kind.self, forKey: .kind)
        time = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .time))   // epoch seconds on the wire
        text = try c.decodeIfPresent(String.self, forKey: .text)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        seen = try c.decodeIfPresent(Bool.self, forKey: .seen)
    }

    /// The wire format again, for the list Ferry keeps on the phone.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(to, forKey: .to)
        try c.encode(kind, forKey: .kind)
        try c.encode(time.timeIntervalSince1970, forKey: .time)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encodeIfPresent(seen, forKey: .seen)
    }
}

/// `api/items`: a computer's box, and how long ago it was last used.
public struct ItemsResponse: Decodable, Sendable {
    public let computer: String
    public let items: [Item]
    public let keep: Int
    /// Seconds since the computer was last used (0: in use); nil when it doesn't know or is an older Ferry.
    public let idle: Int?
    /// The computer's VAPID public key, which the phone's relay address is bound to; nil when it can't notify (no
    /// python3-cryptography).
    public let push: String?

    public init(computer: String, items: [Item], keep: Int, idle: Int?, push: String? = nil) {
        self.computer = computer
        self.items = items
        self.keep = keep
        self.idle = idle
        self.push = push
    }
}

/// One computer in `api/machines`.
public struct MachineInfo: Decodable, Hashable, Sendable {
    public let url: URL
    public let name: String
    /// The computer that answered the request.
    public let isSelf: Bool

    enum CodingKeys: String, CodingKey { case url, name, isSelf = "self" }

    public init(url: URL, name: String, isSelf: Bool = false) {
        self.url = url
        self.name = name
        self.isSelf = isSelf
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        name = try c.decode(String.self, forKey: .name)
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
    }
}

/// `api/machines`: the owner's computers that answer, the asking one included, and the devices the owner forgot.
public struct MachinesResponse: Decodable, Sendable {
    public let machines: [MachineInfo]
    /// The short tailnet names of the devices forgotten on the owner's computers (docs/protocol.md › Forgetting a
    /// device): the app drops the computers among them. Empty from a Ferry that doesn't forget.
    public let forgotten: Set<String>

    enum CodingKeys: String, CodingKey { case machines, forgotten }

    public init(machines: [MachineInfo], forgotten: Set<String> = []) {
        self.machines = machines
        self.forgotten = forgotten
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machines = try c.decode([MachineInfo].self, forKey: .machines)
        // Entry by entry: one the app can't read leaves the rest as they are
        let entries = (try? c.decodeIfPresent([Lenient<Forgetting>].self, forKey: .forgotten)) ?? []
        forgotten = Set(entries.compactMap(\.value).filter(\.forgotten).map(\.device))
    }

    struct Forgetting: Decodable {
        let device: String
        let forgotten: Bool
    }

    /// A value that is nil where the JSON isn't one, rather than failing the whole list
    struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
    }
}

/// A text that is one web address and nothing else: the iPhone's rows and the Mac's open it rather than copy it.
public enum WebLink {
    public static func url(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace), let url = URL(string: t), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }
}
