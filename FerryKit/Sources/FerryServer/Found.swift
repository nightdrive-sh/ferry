import Foundation

/// One of the owner's computers that answered as Ferry.
public struct Probed: Codable, Sendable, Equatable {
    public var url: String
    public var name: String
    /// The short tailnet name
    public var id: String
    public var idle: Int?
    /// Its list of forgotten devices, to merge into this computer's
    public var forgotten: [Forgetting]

    public init(url: String, name: String, id: String, idle: Int?, forgotten: [Forgetting] = []) {
        self.url = url
        self.name = name
        self.id = id
        self.idle = idle
        self.forgotten = forgotten
    }
}

/// A computer the server has seen running Ferry, kept in machines.json for the menu's device list while it sleeps.
public struct KnownComputer: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var url: String
    public var idle: Int?
    /// When it last answered, Unix seconds
    public var seen: Double

    public init(id: String, name: String, url: String, idle: Int?, seen: Double) {
        self.id = id
        self.name = name
        self.url = url
        self.idle = idle
        self.seen = seen
    }
}

/// The owner's other machines running Ferry, from the ones Tailscale has online (bin/ferry's `Found`). A machine is
/// asked when it comes online, again after a minute, and after 10 s if it didn't answer as Ferry (it may have come
/// online before its Ferry started). One that goes offline leaves at once and is never asked: on an iPhone, tries to
/// reach a machine that is off jammed Tailscale's tunnel to the others too.
public actor Found {
    private let config: ServerConfig
    private let probe: @Sendable (String) async -> Probed?
    private let clock: @Sendable () -> TimeInterval
    private var probed: [String: (when: TimeInterval, answer: Probed?)] = [:]
    /// The hosts the last get() asked: only then is there news for machines.json
    public private(set) var asked: [String] = []

    public init(config: ServerConfig, probe: @escaping @Sendable (String) async -> Probed?,
                clock: @escaping @Sendable () -> TimeInterval) {
        self.config = config
        self.probe = probe
        self.clock = clock
    }

    public func get(online: [String]) async -> [Probed] {
        let now = clock()
        let due = online.filter { h in
            guard let p = probed[h] else { return true }
            return now - p.when > (p.answer != nil ? config.probeAgain : config.probeMissedAgain)
        }
        asked = due
        let probe = self.probe
        let results: [String: Probed?] = due.isEmpty ? [:] : await withTaskGroup(of: (String, Probed?)?.self) { group in
            for h in due { group.addTask { (h, await probe(h)) } }
            group.addTask { try? await Task.sleep(for: .seconds(6)); return nil }   // past this, stop waiting
            var out: [String: Probed?] = [:]
            for await r in group {
                guard let (h, p) = r else { group.cancelAll(); break }
                out[h] = p
                if out.count == due.count { group.cancelAll(); break }
            }
            return out
        }
        var kept = probed.filter { online.contains($0.key) }
        for h in due { kept[h] = (now, results[h] ?? nil) }
        probed = kept
        return probed.values.compactMap(\.answer).sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// `api/ping` at a host's Ferry address, with the list of devices forgotten there
    public static func probe(host: String, config: ServerConfig, outbound: any Outbound) async -> Probed? {
        let base = "https://\(host)\(config.httpsPort == 443 ? "" : ":\(config.httpsPort)")\(config.mount)/"
        guard let url = URL(string: base + "api/ping") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: config.probeTimeout)
        req.setValue("1", forHTTPHeaderField: "X-Ferry")
        struct Ping: Decodable { var computer: String?; var idle: Int? }
        guard let (status, body) = try? await outbound.data(req), status == 200,
              let ping = try? JSONDecoder().decode(Ping.self, from: body) else { return nil }
        let id = String(host.split(separator: ".").first ?? "")
        // Read apart from the rest: another computer's list is taken entry by entry, and an older Ferry has none
        let forgotten = Forgotten.entries(from: (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["forgotten"])
        return Probed(url: base, name: ping.computer ?? id, id: id, idle: ping.idle, forgotten: forgotten)
    }

    /// bin/ferry's merge into machines.json: what answered now replaces its old entry, a sleeping one stays while
    /// Tailscale still lists it among the owner's machines (ids)
    public static func merge(known: [KnownComputer], found: [Probed], ids: Set<String>, now: Double) -> [KnownComputer] {
        let foundIDs = Set(found.map(\.id))
        return known.filter { !foundIDs.contains($0.id) && ids.contains($0.id) }
            + found.map { KnownComputer(id: $0.id, name: $0.name, url: $0.url, idle: $0.idle, seen: now) }
    }
}
