import FerryKit
import Foundation
import Security

/// The secret path `tailscale serve` is pointed at (`http://127.0.0.1:47270/<key>`), so the local port answers only
/// Tailscale and this user.
///
/// The server listens on 127.0.0.1, and everything else about who is asking is in headers (Tailscale-User-Login, Host)
/// that any local process could make up. Ferry for Linux asks the kernel whose a connection is; macOS shows a process
/// only its own sockets, and Tailscale's extensions can't reach a Unix socket (their sandbox), so a Mac can't tell. What
/// it can do is be reached only at a path that Tailscale holds and the user's own files keep: the key, made once and
/// kept in Ferry's state (0600). A request that doesn't start with it gets its connection closed without an answer, so
/// another user of the Mac gets nothing, whatever it sends. Who can read Tailscale's serve configuration can read the
/// key: the Mac's administrators (who could become root anyway), and with the open-source tailscaled every user of the
/// Mac. So can one watching the Mac's processes at the moment Ferry publishes itself, as the key is on `tailscale
/// serve`'s command line (docs/protocol.md › Network and trust).
public struct LocalKey: Sendable, Equatable, CustomStringConvertible {
    public let value: String

    init(_ value: String) {
        self.value = value
    }

    /// The key in state, made and saved there the first time
    public static func load(orCreateIn state: URL) throws -> LocalKey {
        let fm = FileManager.default
        let path = state.appending(path: "serve-key")
        if let saved = try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           isKey(saved) {
            return LocalKey(saved)
        }
        try fm.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let key = LocalKey(Data(bytes).base64URL)
        try? fm.removeItem(at: path)
        guard fm.createFile(atPath: path.path, contents: Data(key.value.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return key
    }

    /// 43 base64url characters: 32 random bytes
    static func isKey(_ s: String) -> Bool {
        s.utf8.count == 43 && s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
        }
    }

    /// Where `tailscale serve` sends the requests it publishes
    public func target(port: UInt16) -> String { "http://127.0.0.1:\(port)/\(value)" }

    /// The path a request reached the server at, without the key in front ("/<key>/api/items" → "/api/items"); nil
    /// when it doesn't start with the key. Compared in constant time, so a wrong guess says nothing of how near it was.
    public func strip(_ path: String) -> String? {
        let p = Array(path.utf8)
        let k = Array(value.utf8)
        guard p.count > k.count, p[0] == 0x2F else { return nil }
        var diff: UInt8 = 0
        for i in 0..<k.count { diff |= p[i + 1] ^ k[i] }
        let rest = p.count == k.count + 1 ? [] : Array(p[(k.count + 1)...])
        guard diff == 0, rest.isEmpty || rest[0] == 0x2F else { return nil }
        return rest.isEmpty ? "/" : String(decoding: rest, as: UTF8.self)
    }

    /// Kept out of logs
    public var description: String { "LocalKey(…)" }
}
