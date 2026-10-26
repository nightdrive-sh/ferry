import Foundation
import Synchronization
import Testing
@testable import FerryServer

@Suite struct BoxTests {
    let day: TimeInterval = 86400

    func text(_ t: String, to: String = "phone", for device: String? = nil, at time: TimeInterval) -> BoxItem {
        BoxItem(id: Box.newID(), to: to, kind: "text", time: time, text: t, for: device)
    }

    @Test func newIDs() {
        let id = Box.newID()
        #expect(id.count == 12)
        #expect(id.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(Box.newID() != id)
    }

    @Test func savesAndReloads() async throws {
        let state = tempFolder()
        let clock = TestClock()
        await Box(state: state, keepDays: 7, clock: clock.function).append([text("801566", at: clock.now)])
        let again = await Box(state: state, keepDays: 7, clock: clock.function).items()
        #expect(again.map(\.text) == ["801566"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: state.appending(path: "items.json"))) as? [String: Any]
        #expect((json?["items"] as? [Any])?.count == 1)
    }

    /// docs/protocol.md › Codes and passwords
    @Test func aCodeLeavesAfterFifteenMinutes() async throws {
        let clock = TestClock()
        let box = Box(state: tempFolder(), keepDays: 7, clock: clock.function)
        await box.append([text("801566", at: clock.now), text("Milk, coffee", at: clock.now)])
        clock.advance(14 * 60)
        #expect(await box.items().count == 2)
        clock.advance(2 * 60)
        #expect(await box.items().map(\.text) == ["Milk, coffee"])
    }

    @Test func aCopiedCodeLeaves() async throws {
        let clock = TestClock()
        let box = Box(state: tempFolder(), keepDays: 7, clock: clock.function)
        let code = text("Tr0ub4dor&3", to: "computer", at: clock.now), other = text("Milk, coffee", to: "computer", at: clock.now)
        await box.append([code, other])
        await box.copied(id: other.id)
        await box.copied(id: code.id)
        #expect(await box.items().map(\.id) == [other.id])
    }

    @Test func theListMarksACode() {
        #expect(text("801566", at: 0).wire["secret"] == .bool(true))
        #expect(text("Milk, coffee", at: 0).wire["secret"] == nil)
    }

    @Test func prunesAfterSevenDays() async throws {
        let state = tempFolder()
        let clock = TestClock()
        let box = Box(state: state, keepDays: 7, clock: clock.function)
        await box.append([text("old", at: clock.now)])
        let src = tempFolder().appending(path: "a.pdf")
        try Data("pdf".utf8).write(to: src)
        let left = try await box.leaveFile(src, for: "iphone")
        let folder = state.appending(path: "files/\(left.id)")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "a.pdf").path))
        clock.advance(6.9 * day)
        #expect(await box.items().count == 2)
        clock.advance(0.11 * day)
        #expect(await box.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))   // the copy for the phone went with its item
    }

    @Test func receivedFileGoneIsPruned() async throws {
        let clock = TestClock()
        let box = Box(state: tempFolder(), keepDays: 7, clock: clock.function)
        let file = tempFolder().appending(path: "photo.jpg")
        try Data("jpg".utf8).write(to: file)
        await box.append([BoxItem(id: Box.newID(), to: "computer", kind: "file", time: clock.now, name: "photo.jpg", size: 3,
                                  type: "image/jpeg", from: "iphone", seen: false, path: file.path)])
        #expect(await box.items().count == 1)
        try FileManager.default.removeItem(at: file)
        #expect(await box.items().isEmpty)
    }

    @Test func removeKeepsReceivedFiles() async throws {
        let state = tempFolder()
        let clock = TestClock()
        let box = Box(state: state, keepDays: 7, clock: clock.function)
        let download = tempFolder().appending(path: "photo.jpg")
        try Data("jpg".utf8).write(to: download)
        let received = BoxItem(id: Box.newID(), to: "computer", kind: "file", time: clock.now, name: "photo.jpg", size: 3,
                               type: "image/jpeg", from: "iphone", seen: false, path: download.path)
        await box.append([received])
        let src = tempFolder().appending(path: "a.pdf")
        try Data("pdf".utf8).write(to: src)
        let left = try await box.leaveFile(src, for: "")
        await box.remove(id: received.id)
        #expect(FileManager.default.fileExists(atPath: download.path))   // Downloads keeps it
        await box.remove(id: left.id)
        #expect(!FileManager.default.fileExists(atPath: state.appending(path: "files/\(left.id)").path))
        #expect(FileManager.default.fileExists(atPath: src.path))   // the original is the user's
        #expect(await box.items().isEmpty)
    }

    @Test func pruningReceivedMovesTheCount() async {   // Review Focus 5: an old item leaving tells the menu too
        let clock = TestClock()
        let changes = Mutex(0)
        let box = Box(state: tempFolder(), keepDays: 7, clock: clock.function, changed: { changes.withLock { $0 += 1 } })
        await box.append([BoxItem(id: "aaaaaaaaaaaa", to: "computer", kind: "text", time: clock.now, text: "a", seen: false)])
        #expect(changes.withLock { $0 } == 1)
        clock.advance(8 * 86400)
        await box.prune()
        #expect(changes.withLock { $0 } == 2)
        await box.prune()   // nothing left to drop: no change
        #expect(changes.withLock { $0 } == 2)
    }

    @Test func markSeenWritesOnlyAChange() async throws {
        let state = tempFolder()
        let box = Box(state: state, keepDays: 7, clock: { 1_800_000_000 })
        await box.append([BoxItem(id: "aaaaaaaaaaaa", to: "computer", kind: "text", time: 1_800_000_000, text: "a", seen: false)])
        await box.markSeen()
        let file = state.appending(path: "items.json")
        try FileManager.default.removeItem(at: file)
        await box.markSeen()   // nothing new to see: the popover's 5 s refresh must not rewrite the box
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func clearAndSeen() async {
        let clock = TestClock()
        let box = Box(state: tempFolder(), keepDays: 7, clock: clock.function)
        await box.append([text("for phone", at: clock.now),
                          BoxItem(id: Box.newID(), to: "computer", kind: "text", time: clock.now, text: "x", from: "iphone", seen: false)])
        await box.markSeen()
        #expect(await box.items().first { $0.to == "computer" }?.seen == true)
        await box.clear(to: "computer")
        #expect(await box.items().map(\.to) == ["phone"])
        #expect(await box.find(id: "nope") == nil)
    }

    @Test func listedForDevice() async {
        let clock = TestClock()
        let box = Box(state: tempFolder(), keepDays: 7, clock: clock.function)
        await box.append([text("any", at: clock.now), text("iphone's", for: "iphone", at: clock.now),
                          text("ipad's", for: "ipad", at: clock.now), text("sent", to: "computer", at: clock.now)])
        #expect(await box.listed(for: "iphone").compactMap(\.text) == ["any", "iphone's", "sent"])
        #expect(await box.listed(for: "your phone").compactMap(\.text) == ["any", "sent"])
    }

    @Test func wireHasNoPath() {
        let it = BoxItem(id: "a1b2c3d4e5f6", to: "phone", kind: "file", time: 1.5, name: "a.pdf", size: 3,
                         type: "application/pdf", for: "iphone", path: "/secret/a.pdf")
        let w = it.wire
        #expect(w["name"] == .string("a.pdf"))
        #expect(w["size"] == .int(3))
        #expect(w["type"] == .string("application/pdf"))
        #expect(w["for"] == .string("iphone"))
        #expect(w["time"] == .double(1.5))
        #expect(w["path"] == nil)
        #expect(w["text"] == nil)
    }

    @Test func safeNames() {   // Review Focus 4
        #expect(FileNames.safe("../../.ssh/authorized_keys") == "authorized_keys")
        #expect(FileNames.safe(".zshrc") == "zshrc")
        #expect(FileNames.safe("a\u{0}b/c\\d") == "d")
        #expect(FileNames.safe("") == "file")
        #expect(FileNames.safe("...") == "file")
        #expect(FileNames.safe("Lasku & kuitti.pdf") == "Lasku & kuitti.pdf")
        #expect(FileNames.safe(String(repeating: "a", count: 300)).count == 200)
    }

    @Test func uniqueNames() throws {
        let dir = tempFolder()
        try Data().write(to: dir.appending(path: "x.pdf"))
        try Data().write(to: dir.appending(path: "x (2).pdf.part"))
        #expect(FileNames.unique(dir.appending(path: "x.pdf")).lastPathComponent == "x (3).pdf")
        #expect(FileNames.unique(dir.appending(path: "y.pdf")).lastPathComponent == "y.pdf")
        try Data().write(to: dir.appending(path: "README"))
        #expect(FileNames.unique(dir.appending(path: "README")).lastPathComponent == "README (2)")
    }
}
