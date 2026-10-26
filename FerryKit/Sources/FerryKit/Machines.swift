import Foundation

/// A computer the phone has seen. Kept while it sleeps, so the Send to menu can show it as "can't reach" rather than
/// dropping it (`api/machines` lists only the ones that answer).
public struct KnownMachine: Codable, Hashable, Sendable {
    public var url: URL
    public var name: String
    public var lastSeen: Date
    /// The computer setup was done with: where the others are found, and the target on a tie.
    public var isSetup: Bool
}

/// What the last poll learned about a computer. `reachable == nil`: not asked yet.
public struct MachineStatus: Hashable, Sendable {
    public var reachable: Bool?
    public var idle: Int?
    /// The computer's VAPID key from its last answer, kept while it sleeps.
    public var push: String?
    public init(reachable: Bool? = nil, idle: Int? = nil, push: String? = nil) {
        self.reachable = reachable
        self.idle = idle
        self.push = push
    }
}

public struct MachineList: Codable, Equatable, Sendable {
    public private(set) var machines: [KnownMachine] = []

    public init() {}

    public var setup: KnownMachine? { machines.first(where: \.isSetup) }

    /// One spelling per computer: lowercased host and exactly one trailing slash, so "…/ferry" typed in setup and
    /// "…/ferry/" from `api/machines` are the same machine.
    public static func normalized(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.host = c.host?.lowercased()
        c.scheme = c.scheme?.lowercased()
        let path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        c.path = path.isEmpty ? "/" : "/\(path)/"
        return c.url ?? url
    }

    public mutating func add(_ url: URL, name: String, at time: Date, asSetup: Bool) {
        let url = Self.normalized(url)
        if asSetup { for i in machines.indices { machines[i].isSetup = false } }
        if let i = machines.firstIndex(where: { $0.url == url }) {
            machines[i].name = name
            machines[i].lastSeen = time
            if asSetup { machines[i].isSetup = true }
        } else {
            machines.append(KnownMachine(url: url, name: name, lastSeen: time, isSetup: asSetup || machines.isEmpty))
        }
    }

    public mutating func merge(_ found: [MachineInfo], at time: Date) {
        for m in found { add(m.url, name: m.name, at: time, asSetup: false) }
    }

    public mutating func markSeen(_ url: URL, at time: Date) {
        let url = Self.normalized(url)
        if let i = machines.firstIndex(where: { $0.url == url }) { machines[i].lastSeen = time }
    }

    public mutating func forget(_ url: URL) {
        let url = Self.normalized(url)
        machines.removeAll { $0.url == url }
        promoteIfNoSetup()
    }

    /// A computer's device name, as `api/forget` and `api/machines`' `forgotten` name it: the first label of its
    /// tailnet name. nil for an address that has none (the mock computers' 127.0.0.1).
    public static func device(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), let first = host.split(separator: ".").first,
              !host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return String(first)
    }

    /// The computers forgotten on the owner's devices
    public mutating func forget(devices: Set<String>) {
        machines.removeAll { Self.device($0.url).map(devices.contains) == true }
        promoteIfNoSetup()
    }

    public mutating func forgetStale(now: Date, days: Int = 7) {
        let limit = now.addingTimeInterval(-Double(days) * 86400)
        machines.removeAll { $0.lastSeen < limit }
        promoteIfNoSetup()
    }

    public mutating func makeSetup(_ url: URL) {
        let url = Self.normalized(url)
        guard machines.contains(where: { $0.url == url }) else { return }
        for i in machines.indices { machines[i].isSetup = machines[i].url == url }
    }

    /// Without its setup computer the list would find no new ones: the one seen most recently, the likeliest to answer,
    /// takes its place.
    private mutating func promoteIfNoSetup() {
        guard setup == nil, let i = machines.indices.max(by: { machines[$0].lastSeen < machines[$1].lastSeen }) else { return }
        machines[i].isSetup = true
    }
}

/// Where a send goes: the computer in use, as the PWA's `drawTargets()` decides it.
public enum TargetRule {
    static func reachable(_ s: MachineStatus?) -> Bool { s?.reachable != false }

    static func idle(_ s: MachineStatus?) -> Int {
        guard let s, s.reachable == true, let i = s.idle else { return .max }
        return i
    }

    /// Used last first; a computer that doesn't say after those that do, the setup one first among equals.
    public static func order(_ m: [KnownMachine], status: [URL: MachineStatus]) -> [KnownMachine] {
        m.enumerated().sorted { a, b in
            let (ia, ib) = (idle(status[a.element.url]), idle(status[b.element.url]))
            if ia != ib { return ia < ib }
            if a.element.isSetup != b.element.isSetup { return a.element.isSetup }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The hand-picked computer while it answers; otherwise the reachable one used last; otherwise the setup one.
    public static func target(_ m: [KnownMachine], status: [URL: MachineStatus], manual: URL?) -> URL? {
        if let manual, m.contains(where: { $0.url == manual }), reachable(status[manual]) { return manual }
        let ordered = order(m, status: status)
        return (ordered.first { reachable(status[$0.url]) } ?? m.first(where: \.isSetup) ?? ordered.first)?.url
    }

    public static func usedLabel(_ s: MachineStatus?) -> String {
        guard reachable(s) else { return "can't reach" }
        guard let i = s?.idle else { return "" }
        return i == 0 ? "in use" : "used \(Age.short(Double(i))) ago"
    }
}
