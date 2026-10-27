import FerryKit
import Foundation
import Synchronization
import Testing
@testable import FerryServer

/// A FerryServer on the Task 3 fixture's tailnet, which knows Nightdrive as a computer running Ferry.
struct ServerRig {
    let state = tempFolder()
    let system = FakeSystem()
    let tailscale = FakeTailscale()
    let outbound = FakeOutbound()
    let server: FerryServer

    /// phones: the ones that have used Ferry here (phones.json), which are the ones listed
    init(known: [KnownComputer] = [KnownComputer(id: "nightdrive", name: "Nightdrive",
                                               url: "https://nightdrive.tail1234.ts.net/ferry/", idle: 0, seen: 1)],
         phones: [String] = ["iphone"], port: UInt16? = nil) throws {
        StateFile.save(known, state.appending(path: "machines.json"))
        StateFile.save(phones, state.appending(path: "phones.json"))
        var config = ServerConfig(state: state)
        if let port { config.port = port }   // 0 for a test that starts it: never the port of the Ferry running here
        server = try FerryServer(config: config, system: system, tailscale: tailscale, outbound: outbound)
    }

    func device(_ id: String) async throws -> Device {
        try #require(await server.devices().first { $0.id == id })
    }
}

@Suite struct FerryServerTests {
    @Test func sendTextToPhone() async throws {
        let r = try ServerRig()
        let keys = PushKeys.generate()
        await r.server.pusher.subscribe(Subscription(endpoint: "https://push.nightdrive.sh/push/abc",
                                                     keys: .init(p256dh: keys.p256dh, auth: keys.authString),
                                                     device: "iphone", time: 0, direct: true))
        let iphone = try await r.device("iphone")
        #expect(await r.server.send(.text("801566", clip: false), to: iphone) == nil)
        let item = try #require(await r.server.box.items().last)
        #expect(item.to == "phone" && item.text == "801566" && item.forDevice == "iphone")
        let pushed = try #require(await r.outbound.sent.first { $0.request.url?.host() == "push.nightdrive.sh" })
        let json = try JSONSerialization.jsonObject(with: PushCrypto.decrypt(pushed.body, with: keys)) as? [String: Any]
        #expect(json?["title"] as? String == "MacBook")
        #expect(json?["id"] as? String == item.id)
    }

    /// Add Device goes back to the list when a phone subscribes, which the iPhone app does as soon as it has the computer
    @Test func phonesCountsSubscriptions() async throws {
        let r = try ServerRig()
        #expect(await r.server.phones() == 0)
        let keys = PushKeys.generate()
        let sub = Subscription(endpoint: "https://push.nightdrive.sh/push/abc", keys: .init(p256dh: keys.p256dh, auth: keys.authString),
                               device: "iphone", time: 0, direct: true)
        await r.server.pusher.subscribe(sub)
        await r.server.pusher.subscribe(sub)   // the same phone again
        #expect(await r.server.phones() == 1)
    }

    @Test func sendFilesToPhone() async throws {
        let r = try ServerRig()
        let folder = tempFolder()
        try Data("a".utf8).write(to: folder.appending(path: "a.pdf"))
        try Data("b".utf8).write(to: folder.appending(path: "b.jpg"))
        try Data("h".utf8).write(to: folder.appending(path: ".hidden"))
        let iphone = try await r.device("iphone")
        #expect(await r.server.send(.files([folder]), to: iphone) == nil)   // a folder sends its files, not dotfiles
        #expect(await r.server.box.items().compactMap(\.name) == ["a.pdf", "b.jpg"])
        #expect(await r.server.send(.files([folder.appending(path: "nothing")]), to: iphone) == "No files to send there")
        #expect(await r.server.send(.text("  ", clip: false), to: iphone) == "Nothing to send")
    }

    @Test func sendToComputer() async throws {
        let r = try ServerRig()
        let file = tempFolder().appending(path: "a.pdf")
        try Data("pdf".utf8).write(to: file)
        await r.outbound.set(status: 200, for: "nightdrive.tail1234.ts.net")
        let nd = try await r.device("nightdrive")
        #expect(await r.server.send(.files([file]), to: nd) == nil)
        let up = try #require(await r.outbound.sent.last)
        #expect(up.request.url?.absoluteString == "https://nightdrive.tail1234.ts.net/ferry/api/upload?name=a.pdf&type=application/pdf")
        #expect(up.request.value(forHTTPHeaderField: "X-Ferry") == "1")
        #expect(up.file == file)
        #expect(await r.server.send(.text("801566", clip: true), to: nd) == nil)
        let text = try #require(await r.outbound.sent.last)
        #expect(text.request.url?.absoluteString == "https://nightdrive.tail1234.ts.net/ferry/api/text")
        #expect(try JSONSerialization.jsonObject(with: text.body) as? [String: AnyHashable] == ["text": "801566", "clip": true])
        await r.outbound.set(down: "nightdrive.tail1234.ts.net")
        #expect(await r.server.send(.text("x", clip: false), to: nd) == "Nightdrive didn't answer: it's asleep, or Ferry is off there")
    }

    @Test func clipboardImageToComputer() async throws {   // Final review: an image couldn't go with clip=1
        let r = try ServerRig()
        await r.outbound.set(status: 200, for: "nightdrive.tail1234.ts.net")
        let png = try ClipboardFile.write(Data([1, 2, 3]))
        #expect(await r.server.send(.files([png], clip: true), to: try await r.device("nightdrive")) == nil)
        let up = try #require(await r.outbound.sent.last)
        #expect(up.request.url?.absoluteString == "https://nightdrive.tail1234.ts.net/ferry/api/upload?name=Clipboard.png&type=image/png&clip=1")
    }

    @Test func sendToUnknownComputer() async throws {
        let r = try ServerRig(known: [])
        let studio = Device(id: "studio", name: "Studio", kind: .computer, online: false, inUse: false)
        #expect(await r.server.send(.text("x", clip: false), to: studio) == "Studio isn't running Ferry")
    }

    @Test func pickSticks() async throws {
        let r = try ServerRig()
        #expect(await r.server.target()?.id == "iphone")
        await r.server.pick("nightdrive")
        #expect(await r.server.target()?.id == "nightdrive")
        let again = try FerryServer(config: ServerConfig(state: r.state), system: r.system, tailscale: r.tailscale, outbound: r.outbound)
        #expect(await again.target()?.id == "nightdrive")   // kept across launches
    }

    @Test func machinesListsSelfThenFound() async throws {
        let r = try ServerRig(known: [])
        await r.outbound.set(status: 200, for: "nightdrive.tail1234.ts.net")
        await r.outbound.set(answer: Data(#"{"computer":"Nightdrive","idle":0}"#.utf8), for: "nightdrive.tail1234.ts.net")
        let m = await r.server.machines()
        #expect(m.first == ["url": .string("https://macbook.tail1234.ts.net/ferry/"), "name": .string("MacBook"), "self": .bool(true)])
        #expect(m.dropFirst().first == ["url": .string("https://nightdrive.tail1234.ts.net/ferry/"), "name": .string("Nightdrive")])
        #expect(m.count == 2)
        #expect(await r.server.devices().first?.id == "nightdrive")   // machines.json has it now
    }

    @Test func publishRunsServe() async throws {
        let r = try ServerRig()
        #expect(await r.server.publishState() == .notPublished)
        #expect(await r.server.publish(true) == .published)
        #expect(await r.server.publish(true) == .published)   // already on: not asked again
        let calls = await r.tailscale.serveCalls
        #expect(calls.count == 1)
        #expect(calls.first?.on == true && calls.first?.port == 47270)
        #expect(await r.server.publish(false) == .stopped)
        await r.tailscale.set(serveAnswer: (false, "Serve is not enabled on your tailnet.\nhttps://login.tailscale.com/f/serve?node=abc\n"))
        #expect(await r.server.publish(true) == .problem(message: "https://login.tailscale.com/f/serve?node=abc",
                                                         link: URL(string: "https://login.tailscale.com/f/serve?node=abc")))
    }

    @Test func publishProblems() async throws {
        let r = try ServerRig()
        await r.tailscale.set(status: nil)
        #expect(await r.server.publishState() == .tailscaleOff)
        let missing = try FerryServer(config: ServerConfig(state: tempFolder()), system: FakeSystem(),
                                      tailscale: MissingTailscale(), outbound: FakeOutbound())
        #expect(await missing.publishState() == .tailscaleMissing)
    }

    @Test func receivedNewestFirstAndSeen() async throws {
        let r = try ServerRig()
        await r.server.box.append([BoxItem(id: "aaaaaaaaaaaa", to: "computer", kind: "text", time: 1_800_000_000, text: "old", seen: false),
                                   BoxItem(id: "bbbbbbbbbbbb", to: "phone", kind: "text", time: 1_800_000_001, text: "left"),
                                   BoxItem(id: "cccccccccccc", to: "computer", kind: "text", time: 1_800_000_002, text: "new", seen: false)])
        #expect(await r.server.received().compactMap(\.text) == ["new", "old"])
        await r.server.markSeen()
        #expect(await r.server.received().allSatisfy { $0.seen == true })
    }

    @Test func uploadProgressToComputer() async throws {
        let r = try ServerRig()
        let dir = tempFolder()
        let a = dir.appending(path: "a.bin"), b = dir.appending(path: "b.bin")
        try Data(count: 100).write(to: a)
        try Data(count: 300).write(to: b)
        let seen = Mutex<[Double]>([])
        let error = await r.server.send(.files([a, b]), to: try await r.device("nightdrive")) { p in seen.withLock { $0.append(p) } }
        #expect(error == nil)
        #expect(seen.withLock { $0 } == [0.125, 0.25, 0.625, 1.0])   // bytes: 50, 100, 250, 400 of 400
    }

    @Test func receivedCountFollowsRemovals() async throws {   // Review Focus 5
        let r = try ServerRig()
        var it = r.server.receivedChanged.makeAsyncIterator()
        await r.server.box.append([BoxItem(id: "aaaaaaaaaaaa", to: "computer", kind: "text", time: 1_800_000_000, text: "a", seen: false)])
        #expect(await it.next() != nil)
        await r.server.remove(id: "aaaaaaaaaaaa")
        #expect(await it.next() != nil)
        #expect(await r.server.unseen() == 0)
        await r.server.box.append([BoxItem(id: "bbbbbbbbbbbb", to: "computer", kind: "text", time: 1_800_000_001, text: "b", seen: false)])
        _ = await it.next()
        await r.server.clearReceived()
        #expect(await it.next() != nil)
    }

    @Test func arrivalsAndUnseen() async throws {
        let r = try ServerRig()
        var it = r.server.receivedChanged.makeAsyncIterator()
        await r.server.box.append([BoxItem(id: "aaaaaaaaaaaa", to: "computer", kind: "text", time: 1_800_000_000, text: "hi", seen: false)])
        #expect(await it.next() != nil)
        #expect(await r.server.unseen() == 1)
        await r.server.box.append([BoxItem(id: "bbbbbbbbbbbb", to: "phone", kind: "text", time: 1_800_000_001, text: "left")])
        #expect(await r.server.unseen() == 1)   // what the Mac left for a phone isn't counted
        await r.server.markSeen()
        #expect(await r.server.unseen() == 0)
    }

    @Test func removeAndClearReceived() async throws {
        let r = try ServerRig()
        let file = r.system.downloads.appending(path: "photo.jpg")
        try Data("x".utf8).write(to: file)
        await r.server.box.append([BoxItem(id: "aaaaaaaaaaaa", to: "computer", kind: "text", time: 1_800_000_000, text: "a"),
                                   BoxItem(id: "bbbbbbbbbbbb", to: "computer", kind: "file", time: 1_800_000_001, name: "photo.jpg",
                                           size: 1, path: file.path),
                                   BoxItem(id: "cccccccccccc", to: "phone", kind: "text", time: 1_800_000_002, text: "left")])
        await r.server.remove(id: "aaaaaaaaaaaa")
        #expect(await r.server.received().map(\.id) == ["bbbbbbbbbbbb"])
        await r.server.clearReceived()
        #expect(await r.server.received().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))           // files stay in Downloads
        #expect(await r.server.box.items().map(\.id) == ["cccccccccccc"])   // the other direction stays
    }

    @Test func problemStaysUntilTryAgain() async throws {   // Final review: refresh re-ran serve every 5 s
        let r = try ServerRig()
        let refused = (ok: false, output: "Serve is not enabled on your tailnet.\nhttps://login.tailscale.com/f/serve?node=abc\n")
        await r.tailscale.set(serveAnswer: refused)
        let problem = await r.server.publish(true)
        #expect(problem == .problem(message: "https://login.tailscale.com/f/serve?node=abc",
                                    link: URL(string: "https://login.tailscale.com/f/serve?node=abc")))
        #expect(await r.server.publishState() == problem)     // the step stays, link and all
        #expect(await r.server.publishIfWanted() == problem)  // and nothing runs serve by itself again
        #expect(await r.tailscale.serveCalls.count == 1)
        await r.tailscale.set(serveAnswer: (true, ""))
        #expect(await r.server.publish(true) == .published)    // Try Again asks again
        #expect(await r.tailscale.serveCalls.count == 2)
    }

    @Test func noPublishingAfterAFailedStart() async throws {   // Final review: another app's port would go on the tailnet
        let r = try ServerRig()
        var config = ServerConfig(state: tempFolder())
        config.port = 0
        let first = try FerryServer(config: config, system: FakeSystem(), tailscale: FakeTailscale(), outbound: FakeOutbound())
        config.port = try await first.start()
        let tailscale = FakeTailscale()
        let second = try FerryServer(config: config, system: r.system, tailscale: tailscale, outbound: r.outbound)
        await #expect(throws: (any Error).self) { try await second.start() }
        #expect(await second.publishIfWanted() == .notPublished)
        #expect(await second.publish(true) == .notPublished)
        #expect(await tailscale.serveCalls.isEmpty)
        await first.stop()
    }

    @Test func stoppedOnlyWhileOff() async throws {   // Final review: "off" while devices could still reach it
        let r = try ServerRig()
        #expect(await r.server.publish(true) == .published)
        await r.tailscale.set(serveAnswer: (false, "serve off failed"))
        #expect(await r.server.publish(false) == .problem(message: "serve off failed", link: nil))
        #expect(await r.server.publishState() == .published)   // still served, so not "off"
        // Stopped in Settings, then turned on outside Ferry: it says what is true
        await r.tailscale.set(serveAnswer: (true, ""))
        #expect(await r.server.publish(false) == .stopped)
        _ = await r.tailscale.serve(on: true, port: 47270)
        #expect(await r.server.publishState() == .published)
    }

    @Test func stopPublishingIsRemembered() async throws {
        let r = try ServerRig()
        #expect(await r.server.publish(false) == .stopped)
        #expect(await r.server.publishState() == .stopped)
        #expect(await r.server.publishIfWanted() == .stopped)
        #expect(await r.tailscale.serveCalls.count == 1)   // only the publish(false)
        let again = try FerryServer(config: ServerConfig(state: r.state), system: r.system, tailscale: r.tailscale,
                                    outbound: r.outbound)
        #expect(await again.publishIfWanted() == .stopped)   // also after the app starts again
        #expect(await r.server.publish(true) == .published)
        #expect(await again.publishIfWanted() == .published)
    }
}

struct MissingTailscale: TailscaleCLI {
    func status() async throws -> Data { throw TailscaleNotFound() }
    func serveStatus() async throws -> Data { throw TailscaleNotFound() }
    func serve(on: Bool, port: UInt16) async -> (ok: Bool, output: String) { (false, "") }
}
