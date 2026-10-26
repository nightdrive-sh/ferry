import Foundation

/// A bare computer name ("nightdrive") made whole with the system resolver: with Tailscale's MagicDNS on, the tailnet is
/// a search domain, and the canonical name comes back as nightdrive.tailXXXX.ts.net.
enum NameResolver {
    static func fullName(for bare: String) async -> String? {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_flags = AI_CANONNAME
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(bare, nil, &hints, &result) == 0, let result else { return nil }
            defer { freeaddrinfo(result) }
            guard let c = result.pointee.ai_canonname else { return nil }
            let name = String(cString: c).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return name.hasSuffix(".ts.net") ? name : nil
        }.value
    }
}
