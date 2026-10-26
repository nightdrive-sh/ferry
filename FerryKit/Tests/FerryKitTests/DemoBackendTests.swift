import Foundation
import Testing
@testable import FerryKit

/// The demo's pretend computers, driven through FerryModel as the app drives them.
@MainActor @Suite struct DemoBackendTests {
    let photo = Data("not really a png".utf8)

    /// The app's way in: set up with the demo's MacBook, as with a real computer's address.
    func demo(replyAfter: Duration = .seconds(60), onFirstSend: @escaping @Sendable () async -> Void = {},
              onArrival: @escaping @Sendable (Received) async -> Void = { _ in }) async throws -> (DemoBackend, FerryModel) {
        let backend = DemoBackend(photo: photo, step: .zero, replyAfter: replyAfter, onFirstSend: onFirstSend,
                                  onArrival: onArrival)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let model = FerryModel(backend: backend, store: MachineStore(defaults: defaults), sentHold: .milliseconds(20))
        try await model.setUp(DemoBackend.macBook)
        return (backend, model)
    }

    @Test func setupFindsBothComputersAndWhatTheyHold() async throws {
        let (_, m) = try await demo()
        #expect(Set(m.list.machines.map(\.name)) == ["MacBook", "Desktop"])
        #expect(m.onlineText == "2/2 online")
        #expect(m.target == DemoBackend.macBook)   // in use, the other one used an hour ago
        #expect(m.received.count == 2)
        #expect(m.received.contains { $0.item.kind == .file && $0.machineName == "MacBook" })
        #expect(m.received.contains { $0.item.isLink && $0.machineName == "Desktop" })
        #expect(m.status[DemoBackend.macBook]?.push == nil)   // nothing for the relay to subscribe
    }

    @Test func sendingGoesIntoTheComputersBox() async throws {
        let (backend, m) = try await demo()
        await m.send(.text("hello", clip: true))
        #expect(m.sendState == .sent(to: "MacBook"))
        let box = try await backend.items(DemoBackend.macBook).items
        #expect(box.contains { $0.to == .computer && $0.text == "hello" })
        await m.refresh()
        #expect(m.received.count == 2)   // the phone's own sends aren't in Received
    }

    @Test func aFileIsSentWithItsSize() async throws {
        let (backend, m) = try await demo()
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Data(count: 1234).write(to: file)
        await m.send(.file(file, name: "photo.png", type: "image/png", clip: false))
        #expect(m.sendState == .sent(to: "MacBook"))
        let sent = try #require(try await backend.items(DemoBackend.macBook).items.first { $0.to == .computer })
        #expect(sent.name == "photo.png")
        #expect(sent.size == 1234)
    }

    @Test func somethingArrivesAfterTheFirstSendOnly() async throws {
        let (arrivals, arrived) = AsyncStream.makeStream(of: Received.self)
        let (backend, m) = try await demo(replyAfter: .milliseconds(30), onArrival: { arrived.yield($0) })
        await m.send(.text("one", clip: false))
        var it = arrivals.makeAsyncIterator()
        let r = try #require(await it.next())
        #expect(r.machine == DemoBackend.macBook)
        #expect(r.machineName == "MacBook")
        #expect(r.item.text == DemoBackend.reply)
        await m.refresh()
        #expect(m.received.first?.id == r.id)   // newest first
        await m.send(.text("two", clip: false))
        try await Task.sleep(for: .milliseconds(100))
        let replies = try await backend.items(DemoBackend.macBook).items.filter { $0.to == .phone && $0.kind == .text }
        #expect(replies.count == 1)
    }

    /// The app hears of the first send before the reply: its hint changes, and it keeps running until the reply is in.
    @Test func theFirstSendIsHeardOfOnce() async throws {
        let sends = Counter()
        let (_, m) = try await demo(onFirstSend: { await sends.add() })
        #expect(await sends.count == 0)
        await m.send(.text("one", clip: false))
        #expect(await sends.count == 1)
        await m.send(.text("two", clip: false))
        #expect(await sends.count == 1)
    }

    @Test func thePhotoDownloads() async throws {
        let (_, m) = try await demo()
        let r = try #require(m.received.first { $0.item.kind == .file })
        let file = try await m.download(r)
        #expect(file.lastPathComponent == r.item.name)
        #expect(try Data(contentsOf: file) == photo)
    }

    @Test func removeAndClear() async throws {
        let (backend, m) = try await demo()
        await m.remove(m.received[0])
        #expect(m.received.count == 1)
        await m.clearReceived()
        await m.refresh()
        #expect(m.received.isEmpty)
        #expect(try await backend.items(DemoBackend.desktop).items.isEmpty)
    }

    @Test func anyOtherAddressDoesntAnswer() async throws {
        let backend = DemoBackend(photo: photo)
        await #expect(throws: FerryError.self) { try await backend.ping(URL(string: "https://elsewhere.ts.net/ferry/")!) }
    }
}

private actor Counter {
    private(set) var count = 0
    func add() { count += 1 }
}
