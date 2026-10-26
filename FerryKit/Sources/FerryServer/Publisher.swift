import Foundation

/// The `tailscale` command isn't on this computer. The app's TailscaleCLI throws it, so setup can say "install Tailscale"
/// rather than "turn it on".
public struct TailscaleNotFound: Error {
    public init() {}
}

/// Whether Ferry is on the tailnet, or what stands in the way, for the menu's setup step.
public enum PublishState: Sendable, Equatable {
    case published
    case notPublished
    case tailscaleMissing
    case tailscaleOff
    /// Its user stopped publishing it (Settings), and Ferry doesn't publish again by itself
    case stopped
    /// Tailscale refused: its own words, and the link it gave (e.g. to turn on Serve or HTTPS for the tailnet)
    case problem(message: String, link: URL?)
}

enum Publisher {
    /// bin/ferry's `serving()`: tailscale serve publishes 127.0.0.1:port at mount on the HTTPS port
    static func serving(statusJSON: Data, port: UInt16, httpsPort: Int, mount: String) -> Bool {
        struct Handler: Decodable { var Proxy: String? }
        struct Web: Decodable { var Handlers: [String: Handler]? }
        struct Config: Decodable { var Web: [String: Web]? }
        guard let cfg = try? JSONDecoder().decode(Config.self, from: statusJSON) else { return false }
        return (cfg.Web ?? [:]).contains { host, web in
            let proxy = web.Handlers?[mount]?.Proxy ?? ""
            let trimmed = proxy.hasSuffix("/") ? String(proxy.dropLast()) : proxy
            return host.hasSuffix(":\(httpsPort)") && trimmed.hasSuffix("127.0.0.1:\(port)")
        }
    }

    /// What tailscale serve said when it refused: its last line, and the first link in it. Tailscale's wording isn't
    /// matched, so a new message still reaches the user as it is.
    static func problem(_ output: String) -> PublishState {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let link = output.split(whereSeparator: { $0.isWhitespace }).first { $0.hasPrefix("https://") }.flatMap { URL(string: String($0)) }
        return .problem(message: lines.last ?? "tailscale serve failed", link: link)
    }
}
