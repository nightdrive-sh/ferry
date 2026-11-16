import Foundation
import Testing
@testable import FerryServer

/// The secret path tailscale serve is pointed at, so another user of the Mac can't reach the server (FER-03)
@Suite struct LocalKeyTests {
    @Test func madeOnceAndKept() throws {
        let state = tempFolder().appending(path: "Ferry")
        let key = try LocalKey.load(orCreateIn: state)
        #expect(LocalKey.isKey(key.value))
        #expect(try LocalKey.load(orCreateIn: state) == key)
        let file = state.appending(path: "serve-key").path
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        #expect(try LocalKey.load(orCreateIn: tempFolder()) != key)
        #expect(!"\(key)".contains(key.value))   // kept out of logs
    }

    @Test func aBrokenFileIsMadeAgain() throws {
        let state = tempFolder()
        try Data("short".utf8).write(to: state.appending(path: "serve-key"))
        let key = try LocalKey.load(orCreateIn: state)
        #expect(LocalKey.isKey(key.value))
        #expect(try String(contentsOf: state.appending(path: "serve-key"), encoding: .utf8) == key.value)
    }

    @Test func stripsTheKey() {
        let key = LocalKey(String(repeating: "a", count: 43))
        let k = key.value
        #expect(key.target(port: 47270) == "http://127.0.0.1:47270/\(k)")
        #expect(key.strip("/\(k)/api/items") == "/api/items")
        #expect(key.strip("/\(k)/") == "/")
        #expect(key.strip("/\(k)") == "/")
        #expect(key.strip("/\(k)/ferry/api/ping") == "/ferry/api/ping")
    }

    @Test func anythingElseIsRefused() {
        let key = LocalKey(String(repeating: "a", count: 43))
        let k = key.value
        for path in ["/", "", "/api/items", "/ferry/api/items", "/\(k)x/api", "/\(k.dropLast())/api", "/\(k.dropLast())b",
                     "//\(k)/api", "\(k)/api", "/\(k.uppercased())/api", "/x/\(k)/api"] {
            #expect(key.strip(path) == nil, "\(path)")
        }
    }
}
