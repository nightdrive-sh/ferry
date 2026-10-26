import Foundation

/// What setup is given, a scanned QR code or a typed name, turned into a computer's base URL.
public enum SetupAddress {
    public enum Parsed: Equatable, Sendable {
        case url(URL)
        /// A name without its tailnet ("nightdrive"): the app asks the resolver for the full one (MagicDNS).
        case bareName(String)
        case invalid
    }

    static let mount = "/ferry/"

    /// The page Add Device's QR code links to: with the app installed it is a universal link that opens the app, and
    /// without, the page says what is needed. The computer's address is in the fragment, so the site never receives it.
    public static let addPage = URL(string: "https://nightdrive.sh/ferry/add")!

    /// What Add Device's QR code holds for the computer at `base`.
    public static func link(for base: URL) -> URL {
        URL(string: addPage.absoluteString + "#" + base.absoluteString)!
    }

    /// The add page, with a computer in its fragment or not.
    public static func isLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return (host == addPage.host || host == "www." + addPage.host!)
            && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "ferry/add"
    }

    public static func parse(_ input: String) -> Parsed {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return .invalid }
        // The add page's link (Add Device's QR code today); a bare address is what older computers show
        if let url = URL(string: s), isLink(url) {
            guard let fragment = URLComponents(string: s)?.fragment?.removingPercentEncoding, !fragment.isEmpty,
                  !(URL(string: fragment).map(isLink) ?? false)
            else { return .invalid }
            return parse(fragment)
        }
        if !s.contains("://") && !s.contains(".") && !s.contains("/") {
            return isLabel(s) ? .bareName(s) : .invalid
        }
        guard var c = URLComponents(string: s.contains("://") ? s : "https://" + s),
              let host = c.host?.lowercased(), !host.isEmpty, host.split(separator: ".").allSatisfy({ isLabel(String($0)) })
        else { return .invalid }
        c.host = host
        // tailscale serve is HTTPS only; plain HTTP stays only for this device itself, where the simulator's mock runs
        if c.scheme?.lowercased() != "http" || !(host == "127.0.0.1" || host == "localhost") { c.scheme = "https" }
        let path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        c.path = path.isEmpty ? mount : "/\(path)/"
        c.query = nil
        c.fragment = nil
        return c.url.map(Parsed.url) ?? .invalid
    }

    /// What a computer is called before it has said its own name: its host's first label, or the whole address.
    public static func shortName(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return host.allSatisfy { $0.isNumber || $0 == "." } ? host : String(host.split(separator: ".").first ?? "")
    }

    private static func isLabel(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
