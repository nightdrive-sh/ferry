import FerryKit
import Foundation
import Testing
@testable import FerryServer

/// The iPhone app's own client against the Mac's server on localhost: the protocol checked from both ends. The fixture
/// names this machine 127.0.0.1, so the Host check passes for http://127.0.0.1:<port>, and the session adds the headers
/// tailscale serve would (the owner's login, the iPhone's address).
@Suite(.serialized) struct ClientServerTests {
    struct Pair {
        let system: FakeSystem
        let server: FerryServer
        let client: HTTPBackend
        let machine: URL

        static func make() async throws -> Pair {
            let system = FakeSystem()
            var config = ServerConfig(state: tempFolder())
            config.port = 0
            let server = try FerryServer(config: config, system: system, tailscale: FakeTailscale("tailscale-status-local"),
                                         outbound: FakeOutbound())
            let port = try await server.start()
            let session = URLSessionConfiguration.ephemeral
            session.httpAdditionalHeaders = ["Tailscale-User-Login": "jari@example.com", "X-Forwarded-For": "100.64.0.4"]
            return Pair(system: system, server: server, client: HTTPBackend(configuration: session),
                        machine: URL(string: "http://127.0.0.1:\(port)/ferry/")!)
        }
    }

    let iphone = Device(id: "iphone", name: "iphone", kind: .phone, online: true, inUse: false)

    @Test func pingAndItems() async throws {
        let p = try await Pair.make()
        defer { Task { await p.server.stop() } }
        #expect(try await p.client.ping(p.machine) == "MacBook")
        let items = try await p.client.items(p.machine)
        #expect(items.computer == "MacBook")
        #expect(items.keep == 7)
        #expect(items.idle == 0)
        #expect(items.push != nil)
        #expect(try await p.client.machines(p.machine).machines.first?.isSelf == true)
    }

    @Test func clipboardAcross() async throws {
        let p = try await Pair.make()
        defer { Task { await p.server.stop() } }
        try await p.client.send(.text("See you at eight", clip: true), to: p.machine) { _ in }
        #expect(await p.system.clipboardText == "See you at eight")
        #expect(await p.server.received().first?.from == "iphone")
        // A code is on the clipboard, and so copied: the box doesn't keep it (docs/protocol.md › Codes and passwords)
        try await p.client.send(.text("801566", clip: true), to: p.machine) { _ in }
        #expect(await p.system.clipboardText == "801566")
        #expect(await p.server.received().map(\.text) == ["See you at eight"])
    }

    @Test func fileAcross() async throws {
        let p = try await Pair.make()
        defer { Task { await p.server.stop() } }
        let photo = tempFolder().appending(path: "photo.jpg")
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: photo)
        try await p.client.send(.file(photo, name: "photo.jpg", type: "image/jpeg", clip: false), to: p.machine) { _ in }
        #expect(try Data(contentsOf: p.system.downloads.appending(path: "photo.jpg")) == bytes)
        let item = try #require(await p.server.received().first)
        #expect(item.name == "photo.jpg" && item.size == 200_000 && item.type == "image/jpeg")
    }

    @Test func leftForThePhone() async throws {
        let p = try await Pair.make()
        defer { Task { await p.server.stop() } }
        #expect(await p.server.send(.text("hello", clip: false), to: iphone) == nil)
        let pdf = tempFolder().appending(path: "Lasku & kuitti #2.pdf")
        try Data("pdf bytes".utf8).write(to: pdf)
        #expect(await p.server.send(.files([pdf]), to: iphone) == nil)
        let items = try await p.client.items(p.machine).items
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.to == .phone })
        #expect(items.first?.text == "hello")
        let file = try #require(items.first { $0.kind == .file })
        #expect(file.name == "Lasku & kuitti #2.pdf")
        let got = try await p.client.download(file, from: p.machine)
        #expect(try Data(contentsOf: got) == Data("pdf bytes".utf8))
        #expect(got.lastPathComponent == "Lasku & kuitti #2.pdf")
    }

    @Test func removeAndClear() async throws {
        let p = try await Pair.make()
        defer { Task { await p.server.stop() } }
        _ = await p.server.send(.text("one", clip: false), to: iphone)
        _ = await p.server.send(.text("two", clip: false), to: iphone)
        let items = try await p.client.items(p.machine).items
        try await p.client.remove(items[0].id, on: p.machine)
        #expect(try await p.client.items(p.machine).items.map(\.text) == ["two"])
        try await p.client.clearReceived(on: p.machine)
        #expect(try await p.client.items(p.machine).items.isEmpty)
    }

    /// docs/protocol.md › Forgetting a device: the app's Forget, and what api/machines then tells it
    @Test func forgetLikeTheApp() async throws {
        let p = try await Pair.make()
        defer { Task { await p.server.stop() } }
        try await p.client.forget("studio", on: p.machine)
        #expect(await p.server.forgotten.ids == ["studio"])
        #expect(try await p.client.machines(p.machine).forgotten == ["studio"])
        await #expect(throws: FerryError.self) { try await p.client.forget("studio.tail1234.ts.net", on: p.machine) }
    }

    @Test func subscribeLikeTheApp() async throws {
        let p = try await Pair.make()
        defer { Task { await p.server.stop() } }
        let keys = PushKeys.generate()
        try await p.client.subscribe(URL(string: "https://push.nightdrive.sh/push/abc")!, keys: keys, on: p.machine)
        #expect(await p.server.pusher.subscriptions().first?.device == "iphone")
        try await p.client.unsubscribe(URL(string: "https://push.nightdrive.sh/push/abc")!, on: p.machine)
        #expect(await p.server.pusher.subscriptions().isEmpty)
    }
}
