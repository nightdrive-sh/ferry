import Foundation

/// Tailscale's command: what the server asks of it. The app runs the real `tailscale`; tests answer from fixtures.
public protocol TailscaleCLI: Sendable {
    /// `tailscale status --json`
    func status() async throws -> Data
    /// `tailscale serve status --json`
    func serveStatus() async throws -> Data
    /// Publishes 127.0.0.1:port at /ferry on the tailnet, or stops that
    func serve(on: Bool, port: UInt16) async -> (ok: Bool, output: String)
}

/// The tailnet as `tailscale status --json` shows it, reduced to what Ferry needs (bin/ferry's `Tailnet.load()`).
public struct TailnetView: Sendable, Equatable {
    public struct Peer: Sendable, Equatable {
        /// The short tailnet name, e.g. "iphone": an iPhone's HostName is "localhost", so it is taken from the DNS name
        public var id: String
        public var dnsName: String
        public var os: String
        public var online: Bool
        public var hostName: String
    }

    public var running = false
    /// The LoginName of this machine's user: the only one Ferry answers
    public var owner = ""
    /// This machine's tailnet name, without the trailing dot
    public var me = ""
    /// The owner's machines' tailnet names, this one too
    public var hosts: Set<String> = []
    /// The owner's other machines that are online and could run Ferry (not phones or tablets), sorted
    public var onlineComputers: [String] = []
    /// The owner's other machines' short names, online or not
    public var ids: Set<String> = []
    /// Every machine's short name by its Tailscale IP, for naming who asks
    public var names: [String: String] = [:]
    /// The owner's other machines
    public var peers: [Peer] = []

    static let phoneOSes: Set<String> = ["iOS", "android"]

    public init() {}

    public init(statusJSON: Data) {
        struct Node: Decodable {
            var DNSName: String?
            var HostName: String?
            var OS: String?
            var UserID: Int64?
            var TailscaleIPs: [String]?
            var Online: Bool?
        }
        struct User: Decodable { var LoginName: String? }
        struct Status: Decodable {
            var BackendState: String?
            var `Self`: Node?
            var Peer: [String: Node]?
            var User: [String: User]?
        }
        guard let st = try? JSONDecoder().decode(Status.self, from: statusJSON) else { return }
        let me = st.Self
        let uid = me?.UserID
        func trimmed(_ n: Node) -> String { (n.DNSName ?? "").hasSuffix(".") ? String((n.DNSName ?? "").dropLast()) : n.DNSName ?? "" }
        func short(_ n: Node) -> String { (n.DNSName ?? "").split(separator: ".").first.map(String.init) ?? n.HostName ?? "" }
        let peers = Array((st.Peer ?? [:]).values)
        let mine = peers.filter { $0.UserID == uid && uid != nil && !($0.DNSName ?? "").isEmpty }

        running = st.BackendState == "Running"
        owner = uid.flatMap { st.User?[String($0)]?.LoginName } ?? ""
        self.me = me.map(trimmed) ?? ""
        hosts = Set((mine + (me.map { [$0] } ?? [])).map(trimmed).filter { !$0.isEmpty })
        onlineComputers = mine.filter { $0.Online == true && !Self.phoneOSes.contains($0.OS ?? "") }.map(trimmed).sorted()
        ids = Set(mine.map(short))
        var names: [String: String] = [:]
        for n in peers + (me.map { [$0] } ?? []) {
            for ip in n.TailscaleIPs ?? [] { names[ip] = short(n) }
        }
        self.names = names
        self.peers = mine.map { Peer(id: short($0), dnsName: trimmed($0), os: $0.OS ?? "", online: $0.Online == true,
                                     hostName: $0.HostName ?? "") }
            .sorted { $0.id < $1.id }
    }
}

/// Who may use Ferry (this machine's owner) and the names of the devices asking, read from Tailscale at most once a
/// minute, and again at once when something isn't found: the owner may have just logged in, a phone just joined.
public actor Tailnet {
    private let cli: any TailscaleCLI
    private let clock: @Sendable () -> TimeInterval
    private var cached = TailnetView()
    private var when: TimeInterval?

    public init(cli: any TailscaleCLI, clock: @escaping @Sendable () -> TimeInterval) {
        self.cli = cli
        self.clock = clock
    }

    public func view(force: Bool = false) async -> TailnetView {
        if !force, let when, clock() - when < 60 { return cached }
        let data = try? await cli.status()
        cached = data.map(TailnetView.init(statusJSON:)) ?? TailnetView()
        when = clock()
        return cached
    }

    /// Looks again once when ok fails on the cached view
    private func check(_ ok: (TailnetView) -> Bool) async -> Bool {
        if ok(await view()) { return true }
        return ok(await view(force: true))
    }

    public func allowed(login: String) async -> Bool {
        guard !login.isEmpty else { return false }
        return await check { $0.running && !$0.owner.isEmpty && $0.owner == login }
    }

    /// Whether a request's Host names this machine (tailscale serve passes the name the device used)
    public func forMe(host: String) async -> Bool {
        let name = host.split(separator: ":").count == 2 ? String(host.split(separator: ":")[0]) : host
        guard !name.isEmpty else { return false }
        return await check { !$0.me.isEmpty && $0.me == name }
    }

    /// Whether url (an Origin, a page's or computer's address) is on one of the owner's machines
    public func sameOwner(_ url: String) async -> Bool {
        guard url.hasPrefix("https://"), let host = URLComponents(string: url)?.host else { return false }
        return await check { $0.hosts.contains(host) }
    }

    /// The asking device's short tailnet name from its IP, "" when unknown
    public func device(ip: String) async -> String {
        guard !ip.isEmpty else { return "" }
        if let n = await view().names[ip] { return n }
        return await view(force: true).names[ip] ?? ""
    }

    /// `https://<me>/ferry/`, nil while Tailscale isn't running
    public func baseURL(mount: String = "/ferry", httpsPort: Int = 443) async -> URL? {
        let v = await view()
        guard v.running, !v.me.isEmpty else { return nil }
        return URL(string: "https://\(v.me)\(httpsPort == 443 ? "" : ":\(httpsPort)")\(mount)/")
    }
}
