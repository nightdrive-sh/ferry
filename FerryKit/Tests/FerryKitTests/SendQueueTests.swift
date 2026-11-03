import Foundation
import Testing
@testable import FerryKit

/// A queue in a folder of its own, on the test's clock
func tempQueue(_ clock: TestClock = TestClock()) -> SendQueue {
    SendQueue(folder: FileManager.default.temporaryDirectory.appending(path: "queue-\(UUID().uuidString)"),
              now: { clock.now })
}

/// Sends that wait on the phone for a computer that is asleep or off (docs/protocol.md › Clients › Sends that wait).
@MainActor @Suite struct SendQueueTests {
    @Test func aSendToAComputerThatDoesntAnswerWaitsAndGoesWhenItIsBack() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([nd, mac])
        let queue = tempQueue()
        let m = try model(fake, queue: queue)
        await m.send(.text("https://example.com", clip: true))
        #expect(m.sendState == .waiting(for: "Nightdrive"))
        #expect(m.waiting.map(\.what) == ["https://example.com"])
        #expect(m.waiting.first?.until == t0.addingTimeInterval(3 * 86400))
        var told: [(String, QueuedOutcome)] = []
        m.delivered = { send, outcome in told.append((send.machineName, outcome)) }
        await fake.setDown([mac])
        await m.refresh()
        #expect(m.waiting.isEmpty)
        // Onto the computer's clipboard hours later it would replace what was copied there since: into its box instead
        #expect(await fake.sent.map(\.payload) == [.text("https://example.com", clip: false)])
        #expect(told.map(\.0) == ["Nightdrive"] && told.map(\.1) == [.delivered])
    }

    @Test func oneKnownAsleepIsntTried() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([nd])
        let m = try model(fake, queue: tempQueue())
        await m.refresh()
        m.manual = nd   // picked by hand while asleep: it holds, and the send waits for it
        let before = await fake.calls.count
        await m.send(.text("hi", clip: false))
        #expect(await fake.calls.count == before)
        #expect(m.sendState == .waiting(for: "Nightdrive"))
        #expect(m.manual == nil)
    }

    @Test func aRefusalIsAFailureAndARefusedWaitingSendIsDropped() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.setRefusing(nd, .refused(status: 507, message: "Not enough room"))
        let m = try model(fake, machines: [(nd, "Nightdrive")], queue: tempQueue())
        await m.send(.text("x", clip: false))
        #expect(m.sendState == .failed("Not enough room"))
        #expect(m.waiting.isEmpty)
        // tailscale serve's 502 while the computer's Ferry isn't up yet is no answer: it waits
        await fake.setRefusing(nd, .refused(status: 502, message: "Bad Gateway"))
        await m.send(.text("y", clip: false))
        #expect(m.waiting.count == 1)
        await fake.setRefusing(nd, .refused(status: 413, message: "Too large"))
        var told: [QueuedOutcome] = []
        m.delivered = { _, outcome in told.append(outcome) }
        await m.refresh()
        #expect(m.waiting.isEmpty)
        #expect(told == [.refused("Too large")])
    }

    @Test func filesWaitAsCopiesOldestFirst() async throws {
        let clock = TestClock()
        let queue = tempQueue(clock)
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appending(path: "photo.jpg")
        try Data("jpeg".utf8).write(to: photo)
        try queue.add(.file(photo, name: "photo.jpg", type: "image/jpeg", clip: true), to: nd, name: "Nightdrive")
        clock.advance(1)
        try queue.add(.text("second", clip: false), to: nd, name: "Nightdrive")
        try FileManager.default.removeItem(at: dir)   // the picked file's temporary copy goes: the queue's own stays
        let list = queue.list()
        #expect(list.map(\.what) == ["second", "photo.jpg"])
        #expect(list[1].size == 4)
        let fake = FakeBackend()
        let done = await queue.deliver(to: [nd], with: fake)
        #expect(done.map(\.0.what) == ["photo.jpg", "second"])
        guard case .file(let url, "photo.jpg", "image/jpeg", false) = await fake.sent.first?.payload else {
            Issue.record("not the file without clip")
            return
        }
        #expect(url.lastPathComponent == "photo.jpg")
        #expect(queue.list().isEmpty)
    }

    @Test func aComputerThatStopsAnsweringKeepsTheRest() async throws {
        let queue = tempQueue()
        try queue.add(.text("a", clip: false), to: nd, name: "Nightdrive")
        try queue.add(.text("b", clip: false), to: mac, name: "MacBook")
        let fake = FakeBackend()
        await fake.setDown([nd])
        let done = await queue.deliver(to: [nd, mac], with: fake)
        #expect(done.map(\.0.what) == ["b"])
        #expect(queue.list().map(\.what) == ["a"])
    }

    @Test func threeDaysACodeFifteenMinutes() throws {
        let clock = TestClock()
        let queue = tempQueue(clock)
        try queue.add(.text("see you", clip: false), to: nd, name: "Nightdrive")
        clock.advance(1)
        try queue.add(.text("801566", clip: false), to: nd, name: "Nightdrive")
        #expect(queue.list().first?.what == "Code or password")
        clock.advance(16 * 60)
        #expect(queue.list().map(\.what) == ["see you"])
        clock.advance(3 * 86400)
        #expect(queue.list().isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: queue.folder.path))?.isEmpty == true)
    }

    @Test func cancelledAndForgottenComputersSendsGo() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([nd, mac])
        let queue = tempQueue()
        let m = try model(fake, queue: queue)
        await m.send(.text("one", clip: false))   // to Nightdrive, the setup one; then MacBook isn't known asleep yet
        await m.send(.text("two", clip: false))
        #expect(Set(m.waiting.map(\.machineName)) == ["Nightdrive", "MacBook"])
        m.cancel(try #require(m.waiting.first { $0.what == "two" }))
        #expect(m.waiting.map(\.what) == ["one"])
        await m.forget(nd)
        await m.refresh()
        #expect(m.waiting.isEmpty)
    }

    @Test func aStoredNameIsNeverAPath() {
        #expect(SendQueue.storedName("../../send.json") == "file")
        #expect(SendQueue.storedName("a/b/photo.jpg") == "photo.jpg")
        #expect(SendQueue.storedName(".hidden") == "file")
    }
}
