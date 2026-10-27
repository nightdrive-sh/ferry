#if os(macOS)
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import FerryKit

/// The iPhone app's own client against the Linux server (`linux/bin/ferry`), as `ClientServerTests` runs it against the
/// Mac's: the protocol checked from both ends. `linux/tests/client.sh` runs it against the server Ferry's install script
/// set up in a test machine, and says where that is: `FERRY_LINUX_URL`, its base URL through a tunnel to the machine's
/// 127.0.0.1, and `FERRY_LINUX_SHELL`, a command that runs a shell script (on stdin) there as Ferry's user. Without them
/// (a plain `swift test`) the suite doesn't run.
///
/// There, `tests/fake-tailscale` names the machine 127.0.0.1 and the owner tester@example.com, and the iPhone is
/// 100.64.0.2 (the iPad 100.64.0.3); `xclip` is a pretend clipboard that keeps what it is given in /tmp/fake-clipboard.
@Suite(.serialized, .enabled(if: LinuxServer.configured, "linux/tests/client.sh runs it against a test machine"))
struct LinuxServerTests {
    let linux = LinuxServer()

    @Test func pingAndItems() async throws {
        try linux.reset()
        let name = try await linux.client.ping(linux.machine)
        #expect(!name.isEmpty)
        let items = try await linux.client.items(linux.machine)
        #expect(items.computer == name)
        #expect(items.keep == 7)
        #expect(items.push?.count == 87)
        #expect(items.items.isEmpty)
        let machines = try await linux.client.machines(linux.machine).machines
        #expect(machines.count == 1)
        #expect(machines.first?.isSelf == true)
        #expect(machines.first?.name == name)
        #expect(machines.first?.url == URL(string: "https://127.0.0.1/ferry/"))
    }

    @Test func clipboardAcross() async throws {
        try linux.reset()
        try await linux.client.send(.text("See you at eight", clip: true), to: linux.machine) { _ in }
        #expect(try linux.sh("cat /tmp/fake-clipboard") == "See you at eight")
        let item = try #require(try await linux.client.items(linux.machine).items.first)
        #expect(item.to == .computer && item.kind == .text && item.text == "See you at eight")
        #expect(item.from == "iphone" && item.seen == false)
        // A code is on the clipboard, and so copied: the box doesn't keep it (docs/protocol.md › Codes and passwords)
        try await linux.client.send(.text("801566", clip: true), to: linux.machine) { _ in }
        #expect(try linux.sh("cat /tmp/fake-clipboard") == "801566")
        #expect(try await linux.client.items(linux.machine).items.map(\.text) == ["See you at eight"])
    }

    @Test func typedTextWaits() async throws {
        try linux.reset()
        try await linux.client.send(.text("Hei ä ö 🚢\nline two", clip: false), to: linux.machine) { _ in }
        #expect(try linux.sh("cat /tmp/fake-clipboard 2>/dev/null || echo none") == "none")
        #expect(try await linux.client.items(linux.machine).items.map(\.text) == ["Hei ä ö 🚢\nline two"])
    }

    @Test func fileAcross() async throws {
        try linux.reset()
        let photo = tempFile("photo.jpg")
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: photo)
        let progress = Mutex(0.0)
        try await linux.client.send(.file(photo, name: "photo.jpg", type: "image/jpeg", clip: false), to: linux.machine) { f in
            progress.withLock { $0 = f }
        }
        #expect(try linux.sh("sha256sum ~/Downloads/photo.jpg | cut -c1-64") == sha256(bytes))
        #expect(progress.withLock { $0 } == 1)
        let item = try #require(try await linux.client.items(linux.machine).items.first)
        #expect(item.to == .computer && item.kind == .file && item.from == "iphone")
        #expect(item.name == "photo.jpg" && item.size == 200_000 && item.type == "image/jpeg")
        #expect(try Data(contentsOf: try await linux.client.download(item, from: linux.machine)) == bytes)
    }

    @Test func namesArriveWhole() async throws {
        try linux.reset()
        let file = tempFile("upload.bin")
        try Data("pdf bytes".utf8).write(to: file)
        for _ in 0..<2 {
            try await linux.client.send(.file(file, name: "Lasku & kuitti #2 + 50%.pdf", type: "application/pdf", clip: false),
                                        to: linux.machine) { _ in }
        }
        #expect(try linux.sh("cd ~/Downloads && ls") == "Lasku & kuitti #2 + 50% (2).pdf\nLasku & kuitti #2 + 50%.pdf")
        #expect(Set(try await linux.client.items(linux.machine).items.compactMap(\.name))
                == ["Lasku & kuitti #2 + 50%.pdf", "Lasku & kuitti #2 + 50% (2).pdf"])
    }

    @Test func clipboardImage() async throws {
        try linux.reset()
        let image = tempFile("image.png")
        try Data("png bytes".utf8).write(to: image)
        try await linux.client.send(.file(image, name: "image.png", type: "image/png", clip: true), to: linux.machine) { _ in }
        #expect(try linux.sh("cat /tmp/fake-clipboard") == "png bytes")
        #expect(try linux.sh("cat /tmp/fake-clipboard.args") == "-selection clipboard -t image/png -in")
        #expect(try linux.sh("cat ~/Downloads/image.png") == "png bytes")
    }

    @Test func leftForThePhone() async throws {
        try linux.reset()
        try await linux.usedFerry()
        try linux.sh("""
            ferry send --to iphone hello
            printf 'pdf bytes' > "/tmp/Lasku & kuitti #2.pdf"
            ferry send --to iphone "/tmp/Lasku & kuitti #2.pdf"
            ferry send --to ipad "for the iPad"
            """)
        let items = try await linux.client.items(linux.machine).items
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.to == .phone && $0.from == nil })
        #expect(items.first?.text == "hello")
        let file = try #require(items.first { $0.kind == .file })
        #expect(file.name == "Lasku & kuitti #2.pdf" && file.size == 9 && file.type == "application/pdf")
        let got = try await linux.client.download(file, from: linux.machine)
        #expect(try Data(contentsOf: got) == Data("pdf bytes".utf8))
        #expect(got.lastPathComponent == "Lasku & kuitti #2.pdf")
    }

    @Test func removeAndClear() async throws {
        try linux.reset()
        try await linux.usedFerry()
        try linux.sh("ferry send --to iphone one; ferry send --to iphone two")
        try await linux.client.send(.text("from the phone", clip: false), to: linux.machine) { _ in }
        let items = try await linux.client.items(linux.machine).items
        let one = try #require(items.first { $0.text == "one" })
        try await linux.client.remove(one.id, on: linux.machine)
        try await linux.client.remove("000000000000", on: linux.machine)
        #expect(try await linux.client.items(linux.machine).items.map(\.text) == ["two", "from the phone"])
        try await linux.client.clearReceived(on: linux.machine)
        #expect(try await linux.client.items(linux.machine).items.map(\.text) == ["from the phone"])
    }

    @Test func goneIsRefused() async throws {
        try linux.reset()
        try await linux.usedFerry()
        try linux.sh("printf x > /tmp/gone.txt && ferry send --to iphone /tmp/gone.txt")
        let file = try #require(try await linux.client.items(linux.machine).items.first)
        try await linux.client.remove(file.id, on: linux.machine)
        await #expect(throws: FerryError.refused(status: 404, message: "Not in the box any more")) {
            try await linux.client.download(file, from: linux.machine)
        }
        await #expect(throws: FerryError.refused(status: 400, message: "Empty text")) {
            try await linux.client.send(.text(" ", clip: false), to: linux.machine) { _ in }
        }
    }

    @Test func someoneElseIsRefused() async throws {
        let session = URLSessionConfiguration.ephemeral
        session.httpAdditionalHeaders = ["Tailscale-User-Login": "someone@else.com", "X-Forwarded-For": "100.64.0.9"]
        await #expect(throws: FerryError.refused(status: 403, message: "Ferry answers only its computer's owner, through Tailscale.")) {
            try await HTTPBackend(configuration: session).items(linux.machine)
        }
    }

    @Test func subscribeLikeTheApp() async throws {
        try linux.reset()
        // Nothing listens there: what is left for the phone meanwhile isn't sent anywhere
        let endpoint = URL(string: "https://127.0.0.1:9/push/abc")!
        let keys = PushKeys.generate()
        try await linux.client.subscribe(endpoint, keys: keys, on: linux.machine)
        try await linux.client.subscribe(endpoint, keys: keys, on: linux.machine)
        let subs = try JSONSerialization.jsonObject(with: Data(try linux.sh("cat ~/.local/share/ferry/push.json").utf8))
        let sub = try #require((subs as? [[String: Any]])?.only)
        #expect(sub["endpoint"] as? String == endpoint.absoluteString)
        #expect(sub["device"] as? String == "iphone" && sub["direct"] as? Bool == true)
        #expect((sub["keys"] as? [String: String]) == ["p256dh": keys.p256dh, "auth": keys.authString])
        try linux.sh("ferry send --to iphone 'with a subscription'")
        try await linux.client.unsubscribe(endpoint, on: linux.machine)
        #expect(try linux.sh("cat ~/.local/share/ferry/push.json") == "[]")
    }

    /// docs/protocol.md › Forgetting a device: a phone on the tailnet is listed once it has used Ferry there
    @Test func phonesListedOnceTheyUsedFerry() async throws {
        try linux.reset()
        // No phone has used it yet. The server keeps what it read of phones.json, so it starts again without one.
        try linux.sh("""
            rm -f ~/.local/share/ferry/phones.json
            systemctl --user restart ferry.service
            for _ in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:47270/ && break; sleep 0.2; done
            """)
        #expect(!(try linux.sh("ferry devices")).contains("iphone"))
        _ = try await linux.client.ping(linux.machine)
        let listed = try linux.sh("ferry devices")
        #expect(listed.contains("iphone"))
        #expect(!listed.contains("ipad"))
    }

    /// docs/protocol.md › Forgetting a device: the app's Forget, as the Linux server takes it, and the iPad added again
    /// with Add Device bringing itself back
    @Test func forgetLikeTheApp() async throws {
        try linux.reset()
        try await linux.usedFerry()
        #expect(try linux.sh("ferry devices").contains("ipad"))
        try await linux.client.forget("ipad", on: linux.machine)
        #expect(try await linux.client.machines(linux.machine).forgotten == ["ipad"])
        #expect(!(try linux.sh("ferry devices")).contains("ipad"))
        try await linux.client.unforgetSelf(on: linux.machine)   // the iPhone isn't forgotten: nothing changes
        #expect(try await linux.client.machines(linux.machine).forgotten == ["ipad"])
        try await linux.ipad.unforgetSelf(on: linux.machine)
        #expect(try await linux.client.machines(linux.machine).forgotten.isEmpty)
        #expect(try linux.sh("ferry devices").contains("ipad"))
    }

    private func tempFile(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct LinuxServer {
    static let env = ProcessInfo.processInfo.environment
    static var configured: Bool { env["FERRY_LINUX_URL"] != nil && env["FERRY_LINUX_SHELL"] != nil }

    struct ShellFailed: Error, CustomStringConvertible {
        let script: String
        let status: Int32
        let output: String
        var description: String { "exit \(status): \(script)\n\(output)" }
    }

    let machine = URL(string: env["FERRY_LINUX_URL"] ?? "http://127.0.0.1/ferry/")!
    /// The app's client as tailscale serve would pass it on: the owner, from the iPhone's address
    let client = Self.backend(from: "100.64.0.2")
    /// The same from the iPad's
    let ipad = Self.backend(from: "100.64.0.3")

    static func backend(from address: String) -> HTTPBackend {
        let session = URLSessionConfiguration.ephemeral
        session.httpAdditionalHeaders = ["Tailscale-User-Login": "tester@example.com", "X-Forwarded-For": address]
        return HTTPBackend(configuration: session)
    }

    /// The iPhone and the iPad call the server once: only a phone that has used Ferry there is a device to send to
    func usedFerry() async throws {
        _ = try await client.ping(machine)
        _ = try await ipad.ping(machine)
    }

    /// Runs a shell script on the server's machine (`ferry` is the installed command) and returns its output.
    @discardableResult func sh(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", Self.env["FERRY_LINUX_SHELL"] ?? "false"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        try p.run()
        input.fileHandleForWriting.write(Data("set -e\nferry() { ~/.local/bin/ferry \"$@\"; }\n\(script)\n".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else { throw ShellFailed(script: script, status: p.terminationStatus, output: out) }
        return out
    }

    /// An empty box, Downloads and clipboard, no subscriptions and nothing forgotten, before each test. The phones that
    /// used Ferry stay (the server keeps them in memory too): a test that sends to one calls from it first.
    func reset() throws {
        try sh("""
            ferry clear >/dev/null
            rm -rf ~/Downloads/* /tmp/fake-clipboard /tmp/fake-clipboard.args
            echo '[]' > ~/.local/share/ferry/push.json
            rm -f ~/.local/share/ferry/forgotten.json
            """)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
#endif
