import Foundation
import Testing
@testable import FerryKit

/// Stands in for the computers: answers per machine, fails the ones told to, and records every call.
actor FakeBackend: FerryBackend {
    var boxes: [URL: ItemsResponse] = [:]
    var names: [URL: String] = [:]
    var found: [MachineInfo] = []
    var down: Set<URL> = []
    /// Fail the next call to these, then answer (Tailscale waking up on the phone)
    var downOnce: Set<URL> = []
    func setDownOnce(_ urls: Set<URL>) { downOnce = urls }
    /// Let this many calls to these run out of time before answering (a computer still getting its HTTPS certificate)
    var silent: [URL: Int] = [:]
    func setSilent(_ url: URL, times: Int) { silent[url] = times }
    var slow: [URL: Duration] = [:]
    var slowMachines: Duration?
    var slowDownload: Duration?
    private(set) var calls: [String] = []
    func setSlowDownload(_ d: Duration) { slowDownload = d }
    func setSlow(_ url: URL, _ d: Duration) { slow[url] = d }
    func setSlowMachines(_ d: Duration) { slowMachines = d }

    func set(_ url: URL, name: String, idle: Int?, items: [Item] = [], push: String? = nil) {
        names[url] = name
        boxes[url] = ItemsResponse(computer: name, items: items, keep: 7, idle: idle, push: push)
    }
    func setDown(_ urls: Set<URL>) { down = urls }
    func setFound(_ m: [MachineInfo]) { found = m }
    /// What api/machines says is forgotten
    var forgotten: Set<String> = []
    func setForgotten(_ f: Set<String>) { forgotten = f }

    private func check(_ url: URL, _ call: String) throws {
        calls.append("\(call) \(url.host() ?? "")")
        if downOnce.remove(url) != nil { throw FerryError.unreachable(machine: "waking") }
        if let n = silent[url], n > 0 {
            silent[url] = n - 1
            throw FerryError.unreachable(machine: String(url.host()?.split(separator: ".").first ?? ""), timedOut: true)
        }
        if down.contains(url) { throw FerryError.unreachable(machine: String(url.host()?.split(separator: ".").first ?? "")) }
    }

    func ping(_ machine: URL) async throws -> String { try check(machine, "ping"); return names[machine] ?? "?" }
    func items(_ machine: URL) async throws -> ItemsResponse {
        try check(machine, "items")
        if let d = slow[machine] { try await Task.sleep(for: d) }   // throws CancellationError, as HTTPBackend now does
        return boxes[machine]!
    }
    func machines(_ machine: URL) async throws -> MachinesResponse {
        try check(machine, "machines")
        if let d = slowMachines { try await Task.sleep(for: d) }
        return MachinesResponse(machines: found, forgotten: forgotten)
    }
    func forget(_ device: String, on machine: URL) async throws {
        try check(machine, "forget \(device)")
        forgotten.insert(device)
    }
    func unforget(_ device: String, on machine: URL) async throws {
        try check(machine, "unforget \(device)")
        forgotten.remove(device)
    }
    /// Computers whose Ferry is from before api/unforget's self: they answer it 400
    var noSelf: Set<URL> = []
    func setNoSelf(_ urls: Set<URL>) { noSelf = urls }
    func unforgetSelf(on machine: URL) async throws {
        try check(machine, "unforget self")
        if noSelf.contains(machine) { throw FerryError.refused(status: 400, message: "Not a device's tailnet name") }
    }
    func send(_ payload: SendPayload, to machine: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try check(machine, "send")
        progress(1)
    }
    func download(_ item: Item, from machine: URL) async throws -> URL {
        try check(machine, "download \(item.id)")
        if let d = slowDownload { try await Task.sleep(for: d) }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: item.name ?? item.id)
        try Data([1, 2, 3]).write(to: file)
        return file
    }
    var slowRemove: Duration?
    func setSlowRemove(_ d: Duration) { slowRemove = d }
    func remove(_ id: String, on machine: URL) async throws {
        try check(machine, "remove \(id)")
        if let d = slowRemove { try await Task.sleep(for: d) }
        keep(machine) { $0.id != id }
    }
    func clearReceived(on machine: URL) async throws {
        try check(machine, "clear")
        keep(machine) { $0.to != .phone }
    }
    /// Like a real computer: what was removed is gone from its box
    private func keep(_ machine: URL, _ test: (Item) -> Bool) {
        guard let b = boxes[machine] else { return }
        boxes[machine] = ItemsResponse(computer: b.computer, items: b.items.filter(test), keep: b.keep, idle: b.idle, push: b.push)
    }
    func subscribe(_ endpoint: URL, keys: PushKeys, on machine: URL) async throws {
        try check(machine, "subscribe \(endpoint.lastPathComponent)")
    }
    func unsubscribe(_ endpoint: URL, on machine: URL) async throws {
        try check(machine, "unsubscribe \(endpoint.lastPathComponent)")
    }
}

func makeItem(_ id: String, to: String = "phone", text: String = "x", time: Double) -> Item {
    try! JSONDecoder().decode(Item.self, from: Data(#"{"id":"\#(id)","to":"\#(to)","kind":"text","time":\#(time),"text":"\#(text)"}"#.utf8))
}

func makeFile(_ id: String, size: Int64, type: String = "image/png", time: Double = 100) -> Item {
    try! JSONDecoder().decode(Item.self, from: Data(#"{"id":"\#(id)","to":"phone","kind":"file","time":\#(time),"name":"\#(id).png","size":\#(size),"type":"\#(type)"}"#.utf8))
}

@MainActor
func model(_ fake: FakeBackend, machines: [(URL, String)] = [(nd, "Nightdrive"), (mac, "MacBook")],
           cache: FileCache? = nil, defaults: UserDefaults? = nil, clock: TestClock? = nil) throws -> FerryModel {
    let defaults = try defaults ?? #require(UserDefaults(suiteName: UUID().uuidString))
    var list = MachineList()
    for (i, (url, name)) in machines.enumerated() { list.add(url, name: name, at: t0, asSetup: i == 0) }
    let store = MachineStore(defaults: defaults)
    store.save(list)
    return FerryModel(backend: fake, store: store, now: { clock?.now ?? t0 }, sentHold: .milliseconds(20), cache: cache,
                      wakeRetry: .milliseconds(20))
}

func tempCache() -> FileCache {
    FileCache(directory: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)"))
}

@MainActor @Suite struct FerryModelTests {
    @Test func receivedMergesAndSorts() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 1200, items: [makeItem("a", time: 100), makeItem("c", to: "computer", time: 300)])
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("b", time: 200)])
        let m = try model(fake)
        await m.refresh()
        #expect(m.received.map(\.item.id) == ["b", "a"])           // to the phone only, newest first
        #expect(m.received[0].machine == mac)
        #expect(m.received[0].machineName == "MacBook")
    }

    @Test func statusFromRefresh() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([nd])
        let m = try model(fake)
        await m.refresh()
        #expect(m.status[nd]?.reachable == false)
        #expect(m.status[mac] == MachineStatus(reachable: true, idle: 0))
        #expect(m.target == mac)
    }

    @Test func pushKeysFromPolls() async throws {   // what the registrar plans from
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0, push: "kN")
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        #expect(m.pushKeys == [nd: "kN", mac: String?.none])
        #expect(m.reachableMachines == [nd, mac])
        await fake.setDown([nd, mac])
        await m.refresh()
        #expect(m.pushKeys == [nd: "kN", mac: String?.none])   // a sleeping computer keeps its last key
        #expect(m.reachableMachines.isEmpty)
    }

    @Test func openNoticeCopiesWholeText() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("t1", text: "Milk, coffee", time: 100)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        #expect(await m.openNotice(machine: mac, id: "t1", kind: .text, text: "Milk, coffee") == .copy("Milk, coffee"))
        #expect(m.highlighted == mac.absoluteString + "#t1")
    }

    // MARK: Codes and passwords (docs/protocol.md › Codes and passwords)

    @Test func aCopiedCodeLeavesTheBox() async throws {
        let fake = FakeBackend()
        let now = t0.timeIntervalSince1970
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("c", text: "801566", time: now),
                                                             makeItem("t", text: "Milk, coffee", time: now - 1)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        await m.refresh()
        #expect(m.received.map(\.item.isSecret) == [true, false])
        await m.copied(m.received[1])
        #expect(!(await fake.calls).contains("remove t \(mac.host()!)"))   // another text stays
        await m.copied(m.received[0])
        #expect(await fake.calls.contains("remove c \(mac.host()!)"))
        #expect(m.received.map(\.item.id) == ["t"])
    }

    @Test func aCodeCopiedFromItsNotificationLeavesTheBox() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("c", text: "801566", time: t0.timeIntervalSince1970)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        await m.refresh()
        await fake.setSlowRemove(.seconds(30))   // the copy doesn't wait for the computer to hear of it
        let start = ContinuousClock.now
        #expect(await m.openNotice(machine: mac, id: "c", kind: .text, text: "801566") == .copy("801566"))
        #expect(ContinuousClock.now - start < .seconds(5))
        for _ in 0..<100 where !(await fake.calls.contains("remove c \(mac.host()!)")) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await fake.calls.contains("remove c \(mac.host()!)"))
        #expect(m.received.isEmpty)
    }

    @Test func aCodeThatLeftTheBoxIsntCopiedFromItsNotification() async throws {   // 15 minutes later, or copied
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        #expect(await m.openNotice(machine: mac, id: "c", kind: .text, text: "801566") == .gone)
        // Another text still copies from its notification, also when the computer can't say
        #expect(await m.openNotice(machine: mac, id: "t", kind: .text, text: "Milk, coffee") == .copy("Milk, coffee"))
    }

    @Test func aCodeLeavesTheListAfterFifteenMinutes() async throws {   // also while its computer sleeps
        let fake = FakeBackend()
        let clock = TestClock()
        let now = t0.timeIntervalSince1970
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("c", text: "801566", time: now),
                                                             makeItem("t", text: "Milk, coffee", time: now)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let m = try model(fake, defaults: defaults, clock: clock)
        await m.refresh()
        #expect(m.received.count == 2)
        await fake.setDown([mac, nd])
        clock.advance(15 * 60 + 1)
        await m.refresh()
        #expect(m.received.map(\.item.id) == ["t"])
        #expect(try model(fake, defaults: defaults, clock: clock).received.map(\.item.id) == ["t"])   // nor kept
    }

    @Test func openNoticeFetchesLongText() async throws {   // the payload had no room for it
        let long = String(repeating: "ä", count: 2000)
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("t1", text: long, time: 100)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        #expect(await m.openNotice(machine: mac, id: "t1", kind: .text, text: nil) == .copy(long))
    }

    @Test func openNoticeLongTextUnreachable() async throws {   // Review Focus 5: never the cut preview
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.setDown([mac])
        let m = try model(fake)
        #expect(await m.openNotice(machine: mac, id: "t1", kind: .text, text: nil) == .unreachable(name: "MacBook"))
        #expect(m.highlighted == nil)
    }

    @Test func openNoticeGone() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        #expect(await m.openNotice(machine: mac, id: "t1", kind: .text, text: nil) == .gone)
        #expect(await m.openNotice(machine: mac, id: "f1", kind: .file, text: nil) == .gone)
    }

    @Test func openNoticeFile() async throws {
        let file = try JSONDecoder().decode(Item.self, from: Data(#"{"id":"f1","to":"phone","kind":"file","time":100,"name":"a.png","size":3,"type":"image/png"}"#.utf8))
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [file])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        #expect(await m.openNotice(machine: mac, id: "f1", kind: .file, text: nil) == .shown)
        #expect(m.highlighted == mac.absoluteString + "#f1")
    }

    @Test func openNoticeFromAnUnknownAddressFindsTheItem() async throws {   // an address the app no longer remembers
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("t1", text: "Milk, coffee", time: 100)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        #expect(await m.openNotice(machine: nil, id: "t1", kind: .text, text: "Milk, coffee") == .copy("Milk, coffee"))
        #expect(m.highlighted == mac.absoluteString + "#t1")
        #expect(await m.openNotice(machine: nil, id: "t1", kind: .text, text: nil) == .copy("Milk, coffee"))
        #expect(await m.openNotice(machine: nil, id: "nope", kind: .text, text: nil) == .gone)
    }

    @Test func openNoticeWithoutItem() async throws {   // a test notification
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        #expect(await m.openNotice(machine: mac, id: nil, kind: nil, text: nil) == .shown)
        #expect(m.highlighted == nil)
    }

    @Test func aDownloadSurvivesARelaunch() async throws {   // the file is on the phone, not fetched again
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeFile("f1", size: 3)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let cache = tempCache()
        let first = try model(fake, cache: cache)
        await first.refresh()
        let r = try #require(first.received.first)
        let file = try await first.download(r)
        #expect(file.lastPathComponent == "f1.png")
        let again = try model(fake, cache: cache)
        await again.refresh()
        await fake.setDown([mac])
        #expect(try await again.download(r) == file)
        #expect(await fake.calls.filter { $0.hasPrefix("download f1") }.count == 1)
    }

    @Test func aRefreshFetchesSmallFilesAhead() async throws {   // the thumbnail is there when the list shows
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeFile("small", size: 3), makeFile("big", size: 100_000_000, type: "video/mp4")])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake, cache: tempCache())
        await m.refresh()
        await m.prefetching?.value
        let downloads = await fake.calls.filter { $0.hasPrefix("download") }
        #expect(downloads == ["download small macbook.tail1.ts.net"])
    }

    @Test func anItemGoneFromTheBoxLeavesTheCache() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeFile("f1", size: 3)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let cache = tempCache()
        let m = try model(fake, cache: cache)
        await m.refresh()
        await m.prefetching?.value
        let r = try #require(m.received.first)
        #expect(cache.file(for: r) != nil)
        await fake.set(mac, name: "MacBook", idle: 0, items: [])
        await m.refresh()
        #expect(cache.file(for: r) == nil)
    }

    @Test func loadingShowsWhileAFileDownloads() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeFile("f1", size: 3)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.setSlowDownload(.milliseconds(200))
        let m = try model(fake, cache: tempCache())
        await m.refresh()
        let r = try #require(m.received.first)
        try await Task.sleep(for: .milliseconds(50))
        #expect(m.loading.contains(r.id))
        _ = try await m.download(r)   // joins the download already running, not a second one
        #expect(!m.loading.contains(r.id))
        #expect(await fake.calls.filter { $0.hasPrefix("download f1") }.count == 1)
    }

    @Test func heardFromTheComputersAfterTheFirstPoll() async throws {   // until then the list isn't empty, just unknown
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(nd, name: "Nightdrive", idle: 0)
        let m = try model(fake)
        #expect(!m.hasPolled)
        await m.refresh()
        #expect(m.hasPolled)
    }

    @Test func aWakingRefreshAsksAFailedComputerAgain() async throws {   // Tailscale wakes with the first request
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("t1", time: 100)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.setDownOnce([mac])
        let m = try model(fake)
        await m.refreshWaking()
        #expect(m.status[mac]?.reachable == true)
        #expect(m.received.map(\.item.id) == ["t1"])
        #expect(await fake.calls.filter { $0 == "items macbook.tail1.ts.net" }.count == 2)
        #expect(await fake.calls.filter { $0 == "items nightdrive.tail1.ts.net" }.count == 1)   // it answered the first time
    }

    // The poll and computers that are off. On the phone, Tailscale's tries to reach a machine that is off jammed the
    // tunnel to the others too (task 1394): a computer that doesn't answer isn't asked on every poll.

    @Test func aComputerThatDoesntAnswerIsntAskedOnEveryPoll() async throws {
        let fake = FakeBackend(), clock = TestClock()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([mac])
        let m = try model(fake, clock: clock)
        await m.poll()
        #expect(m.status[mac]?.reachable == false)
        for _ in 0..<5 { clock.advance(5); await m.poll() }
        #expect(await fake.calls.filter { $0 == "items macbook.tail1.ts.net" }.count == 2)    // the first poll and its retry
        #expect(await fake.calls.filter { $0 == "items nightdrive.tail1.ts.net" }.count == 6)
    }

    @Test func aSleepingComputerIsAskedAsSoonAsAnotherSaysItIsOnline() async throws {
        let fake = FakeBackend(), clock = TestClock()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("t1", time: 100)])
        await fake.setDown([mac])
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true)])
        let m = try model(fake, clock: clock)
        await m.poll()
        #expect(m.status[mac]?.reachable == false)
        await fake.setDown([])
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true), MachineInfo(url: mac, name: "MacBook")])
        clock.advance(10)
        await m.poll()
        #expect(m.status[mac]?.reachable == true)
        #expect(m.received.map(\.item.id) == ["t1"])
    }

    @Test func theOthersAreAskedForASleepingOneEvery10Seconds() async throws {
        let fake = FakeBackend(), clock = TestClock()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([mac])
        let m = try model(fake, clock: clock)
        func checks() async -> Int { await fake.calls.filter { $0 == "machines nightdrive.tail1.ts.net" }.count }
        await m.poll()
        #expect(await checks() == 1)
        clock.advance(5); await m.poll()
        #expect(await checks() == 1)
        clock.advance(5); await m.poll()
        #expect(await checks() == 2)
    }

    @Test func withEveryComputerAwakeTheListIsAskedEvery5Minutes() async throws {
        let fake = FakeBackend(), clock = TestClock()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake, clock: clock)
        await m.refreshAll()
        func checks() async -> Int { await fake.calls.filter { $0.hasPrefix("machines") }.count }
        #expect(await checks() == 1)
        clock.advance(60); await m.poll()
        #expect(await checks() == 1)
        clock.advance(240); await m.poll()
        #expect(await checks() == 2)
    }

    @Test func withNobodyAnsweringTheSleepingAreAskedEvery2Minutes() async throws {   // e.g. the phone's Tailscale off
        let fake = FakeBackend(), clock = TestClock()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([nd, mac])
        let m = try model(fake, clock: clock)
        func asked() async -> Int { await fake.calls.filter { $0 == "items macbook.tail1.ts.net" }.count }
        await m.poll()
        #expect(await asked() == 2)
        clock.advance(60); await m.poll()
        #expect(await asked() == 2)
        clock.advance(60); await m.poll()
        #expect(await asked() == 3)
        await fake.setDown([])
        clock.advance(120); await m.poll()
        #expect(m.status[mac]?.reachable == true)
        #expect(m.status[nd]?.reachable == true)
    }

    @Test func comingToTheScreenAsksEveryComputer() async throws {   // back from turning Tailscale on: no 2 minute wait
        let fake = FakeBackend(), clock = TestClock()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([mac])
        let m = try model(fake, clock: clock)
        await m.poll()
        await fake.setDown([])
        clock.advance(5)
        await m.refreshAll()
        #expect(m.status[mac]?.reachable == true)
    }

    @Test func aWakingRefreshDoesntCallItUnreachableAtTheFirstMiss() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.setDownOnce([mac])
        let m = try model(fake)
        let failed = await m.refresh(quietFailures: true)
        #expect(failed == [mac])
        #expect(m.status[mac]?.reachable != false)   // "Can't reach" doesn't flash while it wakes
    }

    @Test func aComputerThatStaysDownIsUnreachableAfterTheRetry() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.setDown([mac])
        let m = try model(fake)
        await m.refreshWaking()
        #expect(m.status[mac]?.reachable == false)
    }

    @Test func aTappedLongTextWaitsForTheComputerToWake() async throws {
        let long = String(repeating: "x", count: 3000)
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("t1", text: long, time: 100)])
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.setDownOnce([mac])
        let m = try model(fake)
        #expect(await m.openNotice(machine: mac, id: "t1", kind: .text, text: nil) == .copy(long))
    }

    @Test func theListShowsAtLaunchBeforeTheComputersAnswer() async throws {   // Jari: empty after a restart
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil, items: [makeItem("a", text: "Milk, coffee", time: 100)])
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("b", time: 200)])
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let first = try model(fake, defaults: defaults)
        await first.refresh()
        let again = try model(fake, defaults: defaults)
        #expect(again.received.map(\.item.id) == ["b", "a"])
        #expect(again.received.last?.item.text == "Milk, coffee")   // a text can be copied before anything answers
        #expect(again.received.last?.machineName == "Nightdrive")
    }

    @Test func aRemoveWhileUnreachableStaysRemovedAndReachesTheComputerLater() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil, items: [makeItem("a", time: 100)])
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("b", time: 200)])
        let m = try model(fake)
        await m.refresh()
        await fake.setDown([nd])
        await m.remove(m.received.first { $0.item.id == "a" }!)
        #expect(m.received.map(\.item.id) == ["b"])
        await m.refresh()
        #expect(m.received.map(\.item.id) == ["b"])   // its computer still has it, but it stays gone here
        await fake.setDown([])
        await m.refresh()
        await m.refresh()
        #expect(m.received.map(\.item.id) == ["b"])
        #expect(await fake.calls.filter { $0 == "remove a nightdrive.tail1.ts.net" }.count == 2)
    }

    @Test func aClearWhileUnreachableClearsLaterAndLetsNewItemsIn() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil, items: [makeItem("a", time: 100)])
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("b", time: 200)])
        let m = try model(fake)
        await m.refresh()
        await fake.setDown([nd])
        await m.clearReceived()
        #expect(m.received.isEmpty)   // at once, whatever answers
        await fake.set(nd, name: "Nightdrive", idle: nil, items: [makeItem("a", time: 100), makeItem("c", time: 300)])
        await fake.setDown([])
        await m.refresh()
        #expect(m.received.map(\.item.id) == ["c"])   // sent after the clear: it shows
        #expect(await fake.calls.filter { $0 == "clear nightdrive.tail1.ts.net" }.count == 2)
    }

    @Test func pendingRemovalsSurviveARelaunch() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil, items: [makeItem("a", time: 100)])
        await fake.set(mac, name: "MacBook", idle: 0)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let m = try model(fake, defaults: defaults)
        await m.refresh()
        await fake.setDown([nd])
        await m.remove(m.received[0])
        let again = try model(fake, defaults: defaults)
        #expect(again.received.isEmpty)
        await fake.setDown([])
        await again.refresh()
        #expect(again.received.isEmpty)
        #expect(await fake.calls.filter { $0 == "remove a nightdrive.tail1.ts.net" }.count == 2)
    }

    @Test func onlineText() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([nd])
        let m = try model(fake)
        await m.refresh()
        #expect(m.onlineText == "1/2 online")
        let single = try model(fake, machines: [(mac, "MacBook")])
        await single.refresh()
        #expect(single.onlineText == "MacBook")
    }

    @Test func unreachableKeepsItsLastItems() async throws {   // a text can still be copied while its computer sleeps
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil, items: [makeItem("a", time: 100)])
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        await fake.setDown([nd])
        await m.refresh()
        #expect(m.received.map(\.item.id) == ["a"])
    }

    @Test func emptyClipboard() async throws {   // Review Focus 3
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake, machines: [(mac, "MacBook")])
        m.manual = mac
        await m.send(nil)
        #expect(m.sendState == .failed("Clipboard is empty"))
        #expect(await fake.calls.isEmpty)
        #expect(m.manual == mac)
    }

    @Test func allUnreachable() async throws {   // Review Focus 4
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([nd, mac])
        let m = try model(fake)
        await m.refresh()
        #expect(m.onlineText == "0/2 online")
        await m.send(.text("801566", clip: true))
        #expect(m.sendState == .failed("Can't reach Nightdrive"))   // the setup one, as nothing answers
    }

    @Test func sentClearsManual() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 1200)
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        m.manual = nd
        await m.send(.text("801566", clip: true))
        #expect(m.sendState == .sent(to: "Nightdrive"))
        #expect(m.manual == nil)
        #expect(m.target == mac)
        #expect(await fake.calls.last == "send nightdrive.tail1.ts.net")
    }

    @Test func batchGoesToOneTarget() async throws {   // several photos picked by hand all go where the first went
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 1200)
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        m.manual = nd
        let f = FileManager.default.temporaryDirectory
        await m.send([.file(f, name: "a.jpg", type: "image/jpeg", clip: false), .file(f, name: "b.jpg", type: "image/jpeg", clip: false)])
        #expect(await fake.calls.filter { $0.hasPrefix("send") } == ["send nightdrive.tail1.ts.net", "send nightdrive.tail1.ts.net"])
        #expect(m.sendState == .sent(to: "Nightdrive"))
        #expect(m.manual == nil)
    }

    @Test func batchStopsAtTheFirstFailure() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([mac])
        let m = try model(fake, machines: [(mac, "MacBook")])
        let f = FileManager.default.temporaryDirectory
        await m.send([.file(f, name: "a.jpg", type: "image/jpeg", clip: false), .file(f, name: "b.jpg", type: "image/jpeg", clip: false)])
        #expect(await fake.calls.count == 1)
        #expect(m.sendState == .failed("Can't reach MacBook"))
    }

    @Test func failedKeepsManual() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 1200)
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        m.manual = nd
        await fake.setDown([nd])
        await m.send(.text("x", clip: false))
        #expect(m.sendState == .failed("Can't reach Nightdrive"))
        #expect(m.manual == nd)
    }

    @Test func sentReturnsToIdle() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake, machines: [(mac, "MacBook")])
        await m.send(.text("x", clip: true))
        #expect(m.sendState == .sent(to: "MacBook"))
        try await Task.sleep(for: .milliseconds(80))
        #expect(m.sendState == .idle)
    }

    @Test func setUpRequiresPing() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true), MachineInfo(url: mac, name: "MacBook")])
        await fake.set(mac, name: "MacBook", idle: 50)
        let m = try model(fake, machines: [])
        #expect(!m.isSetUp)
        await fake.setDown([nd])
        await #expect(throws: FerryError.self) { try await m.setUp(nd) }
        #expect(m.list.machines.isEmpty)
        await fake.setDown([])
        try await m.setUp(URL(string: "https://nightdrive.tail1.ts.net/ferry")!)
        #expect(m.isSetUp)
        #expect(m.list.setup?.url == nd)
        #expect(m.list.machines.count == 2)                        // MacBook found through Nightdrive
    }

    @Test func refreshMachinesFallsBackWhenSetupSleeps() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setFound([MachineInfo(url: mac, name: "MacBook", isSelf: true), MachineInfo(url: mini, name: "Mini")])
        await fake.setDown([nd])
        let m = try model(fake)
        await m.refresh()
        await m.refreshMachines()
        #expect(m.list.machines.map(\.name).sorted() == ["MacBook", "Mini", "Nightdrive"])
    }

    @Test func removeCallsItsMachine() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil, items: [makeItem("a", time: 100)])
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("b", time: 200)])
        let m = try model(fake)
        await m.refresh()
        await m.remove(m.received.first { $0.item.id == "a" }!)
        #expect(await fake.calls.contains("remove a nightdrive.tail1.ts.net"))
        #expect(m.received.map(\.item.id) == ["b"])
    }

    @Test func clearAsksEveryMachine() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil, items: [makeItem("a", time: 100)])
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("b", time: 200)])
        let m = try model(fake)
        await m.refresh()
        await m.clearReceived()
        let calls = await fake.calls
        #expect(calls.contains("clear nightdrive.tail1.ts.net") && calls.contains("clear macbook.tail1.ts.net"))
        #expect(m.received.isEmpty)
    }

    @Test func seenPersists() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("b", time: 200)])
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var list = MachineList()
        list.add(mac, name: "MacBook", at: t0, asSetup: true)
        MachineStore(defaults: defaults).save(list)
        let m = FerryModel(backend: fake, store: MachineStore(defaults: defaults), now: { t0 })
        await m.refresh()
        #expect(m.isNew(m.received[0]))
        m.markAllSeen()
        let again = FerryModel(backend: fake, store: MachineStore(defaults: defaults), now: { t0 })
        await again.refresh()
        #expect(!again.isNew(again.received[0]))
    }

    @Test func forgetMovesTheTargetAndSaves() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 1200, items: [makeItem("a", time: 100)])
        await fake.set(mac, name: "MacBook", idle: 0)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var list = MachineList()
        list.add(nd, name: "Nightdrive", at: t0, asSetup: true)
        list.add(mac, name: "MacBook", at: t0, asSetup: false)
        MachineStore(defaults: defaults).save(list)
        let m = FerryModel(backend: fake, store: MachineStore(defaults: defaults), now: { t0 })
        await m.refresh()
        #expect(m.target == mac)
        await m.forget(mac)
        #expect(m.target == nd)
        #expect(m.status[mac] == nil)
        #expect(MachineStore(defaults: defaults).load().machines.map(\.url) == [nd])
        await m.forget(nd)
        #expect(!m.isSetUp)
        #expect(m.received.isEmpty)                                // its items go with it
    }

    // A computer just set up answers once tailscaled has its HTTPS certificate, about 37 s after it is published: until
    // then every try runs out of time, and setup keeps asking for as long as it is patient
    @Test func setUpWaitsForAComputerGettingItsCertificate() async throws {
        let fake = FakeBackend()
        await fake.set(mini, name: "Mini", idle: nil)
        await fake.setSilent(mini, times: 2)
        let m = try model(fake, machines: [])
        var waits = 0
        try await m.setUp(mini, patience: .seconds(5), retryAfter: .milliseconds(10)) { waits += 1 }
        #expect(m.isSetUp)
        #expect(m.list.setup?.url == mini)
        #expect(waits == 1)                                        // said once, when the first try ran out of time
        #expect(await fake.calls.filter { $0.hasPrefix("ping") }.count == 3)
    }

    @Test func setUpWithoutPatienceTriesOnce() async throws {   // the mock's own setup, the demo
        let fake = FakeBackend()
        await fake.set(mini, name: "Mini", idle: nil)
        await fake.setSilent(mini, times: 1)
        let m = try model(fake, machines: [])
        await #expect(throws: FerryError.unreachable(machine: "mini", timedOut: true)) { try await m.setUp(mini) }
        #expect(!m.isSetUp)
        #expect(await fake.calls.filter { $0.hasPrefix("ping") }.count == 1)
    }

    @Test func setUpDoesntWaitForAnAnswerThatIsNo() async throws {   // no such name, nothing listening: said at once
        let fake = FakeBackend()
        await fake.setDown([mini])
        let m = try model(fake, machines: [])
        var waits = 0
        await #expect(throws: FerryError.unreachable(machine: "mini")) {
            try await m.setUp(mini, patience: .seconds(5), retryAfter: .milliseconds(10)) { waits += 1 }
        }
        #expect(waits == 0)
        #expect(await fake.calls.filter { $0.hasPrefix("ping") }.count == 1)
    }

    @Test func setUpGivesUpAfterItsPatience() async throws {
        let fake = FakeBackend()
        await fake.setSilent(mini, times: .max)
        let m = try model(fake, machines: [])
        let start = ContinuousClock.now
        await #expect(throws: FerryError.unreachable(machine: "mini", timedOut: true)) {
            try await m.setUp(mini, patience: .milliseconds(100), retryAfter: .milliseconds(10))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await fake.calls.filter { $0.hasPrefix("ping") }.count > 1)
        #expect(!m.isSetUp)
    }

    @Test func cancellingTheWaitAddsNothing() async throws {   // the Cancel button under "Waiting for …"
        let fake = FakeBackend()
        await fake.set(mini, name: "Mini", idle: nil)
        await fake.setSilent(mini, times: .max)
        let m = try model(fake, machines: [])
        let setUp = Task { try await m.setUp(mini, patience: .seconds(30), retryAfter: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(60))
        setUp.cancel()
        await #expect(throws: CancellationError.self) { try await setUp.value }
        #expect(!m.isSetUp)
    }

    @Test func addingAComputerKeepsTheSetupOne() async throws {   // Settings › Add a Computer
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil)
        await fake.set(mini, name: "Mini", idle: nil)
        let m = try model(fake, machines: [(nd, "Nightdrive")])
        try await m.setUp(mini, asSetup: false)
        #expect(m.list.machines.count == 2)
        #expect(m.list.setup?.url == nd)
    }

    @Test func makeSetupSaves() async throws {
        let fake = FakeBackend()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var list = MachineList()
        list.add(nd, name: "Nightdrive", at: t0, asSetup: true)
        list.add(mac, name: "MacBook", at: t0, asSetup: false)
        MachineStore(defaults: defaults).save(list)
        let m = FerryModel(backend: fake, store: MachineStore(defaults: defaults), now: { t0 })
        m.makeSetup(mac)
        #expect(m.list.setup?.url == mac)
        #expect(MachineStore(defaults: defaults).load().setup?.url == mac)
    }

    @Test func aCancelledPollMarksNothingUnreachable() async throws {   // review 1
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: nil)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setSlow(nd, .seconds(5))                           // asleep: its answer never comes in time
        let m = try model(fake)
        let poll = Task { await m.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        poll.cancel()
        await poll.value
        #expect(m.status[nd]?.reachable != false)
        #expect(m.status[mac]?.reachable == true)
        #expect(m.target == mac)
    }

    @Test func itemsArriveWithoutWaitingForMachines() async throws {   // review 2
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0, items: [makeItem("a", time: 100)])
        await fake.setSlowMachines(.seconds(3))
        let m = try model(fake, machines: [(nd, "Nightdrive")])
        let all = Task { await m.refreshAll() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.received.map(\.item.id) == ["a"])
        all.cancel()
        await all.value
    }

    @Test func tryAgainResendsATypedText() async throws {   // review 4
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([mac])
        let m = try model(fake, machines: [(mac, "MacBook")])
        await m.send(.text("typed", clip: false))
        #expect(m.canRetry)
        await fake.setDown([])
        await m.retry()
        #expect(m.sendState == .sent(to: "MacBook"))
        #expect(await fake.calls.filter { $0.hasPrefix("send") }.count == 2)
        #expect(!m.canRetry)
    }

    @Test func aFailedClipboardSendIsNotKeptForRetry() async throws {   // a stale code must not go on Try again
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([mac])
        let m = try model(fake, machines: [(mac, "MacBook")])
        await m.send(.text("801566", clip: true))
        #expect(!m.canRetry)
    }

    @Test func pickingAComputerAfterAFailedClipboardSendStartsOver() async throws {   // Jari: stuck on Try again
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 1200)
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        await fake.setDown([mac])
        await m.send(.text("801566", clip: true))
        #expect(m.sendState == .failed("Can't reach MacBook"))
        m.manual = nd
        #expect(m.sendState == .idle)
    }

    @Test func pickingAComputerAfterAFailedTypedTextKeepsItForTryAgain() async throws {   // it goes to the one picked
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 1200)
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        await fake.setDown([mac])
        await m.send(.text("typed", clip: false))
        m.manual = nd
        #expect(m.sendState == .failed("Not sent"))
        #expect(m.canRetry)
        await m.retry()
        #expect(m.sendState == .sent(to: "Nightdrive"))
        #expect(await fake.calls.last == "send nightdrive.tail1.ts.net")
    }

    @Test func aRetriedBatchSendsWhatDidntArrive() async throws {
        let fake = FakeBackend()
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([mac])
        let m = try model(fake, machines: [(mac, "MacBook")])
        let f = FileManager.default.temporaryDirectory
        await m.send([.file(f, name: "a.jpg", type: "image/jpeg", clip: false), .file(f, name: "b.jpg", type: "image/jpeg", clip: false)])
        await fake.setDown([])
        await m.retry()
        #expect(await fake.calls.filter { $0.hasPrefix("send") }.count == 3)   // 1 failed + both again
    }

    @Test func aFileIsDownloadedOnceAndDeletedWithItsItem() async throws {   // review 5
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0, items: [makeItem("a", time: 100)])
        let m = try model(fake, machines: [(nd, "Nightdrive")])
        await m.refresh()
        let r = m.received[0]
        let first = try await m.download(r)
        let second = try await m.download(r)
        #expect(first == second)
        #expect(await fake.calls.filter { $0.hasPrefix("download") }.count == 1)
        await m.remove(r)
        #expect(!FileManager.default.fileExists(atPath: first.path()))
    }

    @Test func errorMessages() {
        #expect(FerryError.unreachable(machine: "nightdrive").message == "Can't reach nightdrive")
        #expect(FerryError.refused(status: 404, message: "Not in the box any more").message == "Not in the box any more")
        #expect(FerryError.emptyClipboard.message == "Clipboard is empty")
        #expect(FerryError.noMachine.message == "No computer set up")
    }

    // MARK: Forgetting a computer on every device (docs/protocol.md › Forgetting a device)

    @Test func forgetTellsAnotherComputer() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        await m.forget(mac)
        #expect(await fake.calls.last == "forget macbook nightdrive.tail1.ts.net")
        #expect(m.list.machines.map(\.url) == [nd])
    }

    /// With no other computer answering, the one forgotten is told itself, and passes it on to the others
    @Test func forgetTellsTheForgottenOneWhenNoOtherAnswers() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.setDown([nd])
        let m = try model(fake)
        await m.refresh()
        await m.forget(mac)
        #expect(await fake.calls.last == "forget macbook macbook.tail1.ts.net")
    }

    /// Nobody answers: kept, and sent with the next refresh that reaches a computer; meanwhile api/machines doesn't
    /// bring it back
    @Test func forgetWaitsForAComputerThatAnswers() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(mini, name: "Mini", idle: 0)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let m = try model(fake, machines: [(nd, "Nightdrive"), (mac, "MacBook"), (mini, "Mini")], defaults: defaults)
        await m.refresh()
        await fake.setDown([nd, mac, mini])
        await m.forget(mini)
        #expect(m.list.machines.map(\.url) == [nd, mac])
        await fake.setDown([])
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true), MachineInfo(url: mini, name: "Mini")])
        await m.refreshMachines()
        #expect(m.list.machines.map(\.url) == [nd, mac])
        // Kept across launches too
        let again = FerryModel(backend: fake, store: MachineStore(defaults: defaults), now: { t0 })
        await again.refresh()
        #expect(await fake.calls.contains { $0.hasPrefix("forget mini ") })
        #expect(await fake.forgotten == ["mini"])
        let calls = await fake.calls.count
        await again.refresh()
        #expect(await fake.calls.count == calls + 2)   // sent once: only the two boxes asked now
    }

    /// Forgotten on another device: api/machines says so, and the phone drops it, with what it held
    @Test func refreshMachinesDropsWhatWasForgottenElsewhere() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0, items: [makeItem("b", time: 200)])
        let m = try model(fake)
        await m.refresh()
        #expect(m.received.count == 1)
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true)])
        await fake.setForgotten(["macbook"])
        await m.refreshMachines()
        #expect(m.list.machines.map(\.url) == [nd])
        #expect(m.received.isEmpty)
    }

    /// The answering computer lists itself even when it is forgotten: it goes all the same
    @Test func theAnsweringComputerForgottenGoesToo() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true), MachineInfo(url: mac, name: "MacBook")])
        await fake.setForgotten(["nightdrive"])
        await m.refreshMachines()
        #expect(m.list.machines.map(\.url) == [mac])
        #expect(m.list.setup?.url == mac)
    }

    /// Told to one computer, it reaches the others within about a minute: until api/machines says so, a computer that
    /// hasn't heard yet would bring it back (for good, from an older Ferry that never hears)
    @Test func forgetHidesItUntilTheComputersAgree() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(mini, name: "Mini", idle: 0)
        let clock = TestClock()
        let m = try model(fake, machines: [(nd, "Nightdrive"), (mac, "MacBook"), (mini, "Mini")], clock: clock)
        await m.refresh()
        await m.forget(mini)
        await fake.setForgotten([])   // the computer asked next hasn't heard yet
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true), MachineInfo(url: mac, name: "MacBook"),
                             MachineInfo(url: mini, name: "Mini")])
        await m.refreshMachines()
        #expect(!m.list.machines.contains { $0.url == mini })
        clock.advance(11 * 60)   // never heard of it: back after a while
        await m.refreshMachines()
        #expect(m.list.machines.contains { $0.url == mini })
    }

    /// Once the computers agree, its coming back on them (its Ferry started again) brings it back to the phone at once
    @Test func agreedItComesBackWhenBroughtBack() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        let m = try model(fake)
        await m.refresh()
        await m.forget(mac)
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true), MachineInfo(url: mac, name: "MacBook")])
        await m.refreshMachines()   // forgotten there too
        #expect(m.list.machines.map(\.url) == [nd])
        await fake.setForgotten([])
        await m.refreshMachines()
        #expect(m.list.machines.map(\.url).sorted { $0.absoluteString < $1.absoluteString } == [mac, nd])
    }

    /// Setting up with a computer (its QR code, its name) is the phone added with Add Device: it brings itself back on
    /// that computer and on every other that answers, in case it was forgotten (docs/protocol.md › Forgetting a device)
    @Test func settingUpBringsThePhoneItselfBack() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.set(mac, name: "MacBook", idle: 0)
        await fake.set(mini, name: "Mini", idle: 0)
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true), MachineInfo(url: mac, name: "MacBook")])
        await fake.setNoSelf([mac])   // a Ferry from before: its 400 changes nothing
        let m = try model(fake, machines: [(mini, "Mini")])
        await fake.setDown([mini])
        #expect(m.setUps == 0)
        try await m.setUp(nd)
        let calls = await fake.calls.filter { $0.hasPrefix("unforget self") }.sorted()
        #expect(calls == ["unforget self macbook.tail1.ts.net", "unforget self nightdrive.tail1.ts.net"])   // not the one asleep
        #expect(m.setUps == 1)
        #expect(m.list.machines.count == 3)
        // Scanned again: added again
        try await m.setUp(nd)
        #expect(m.setUps == 2)
    }

    @Test func aSetUpThatFailsIsNoAdding() async throws {
        let fake = FakeBackend()
        await fake.setDown([nd])
        let m = try model(fake, machines: [])
        await #expect(throws: FerryError.self) { try await m.setUp(nd) }
        #expect(m.setUps == 0)
        #expect(await fake.calls.filter { $0.hasPrefix("unforget self") }.isEmpty)
    }

    /// Adding a computer by hand (its QR code, its name) is bringing it back: otherwise it would leave the list the moment
    /// its own api/machines said it was forgotten
    @Test func settingUpAForgottenComputerBringsItBack() async throws {
        let fake = FakeBackend()
        await fake.set(nd, name: "Nightdrive", idle: 0)
        await fake.setFound([MachineInfo(url: nd, name: "Nightdrive", isSelf: true)])
        await fake.setForgotten(["nightdrive", "studio"])
        let m = try model(fake, machines: [])
        try await m.setUp(nd)
        #expect(m.list.machines.map(\.url) == [nd])
        #expect(await fake.calls.contains("unforget nightdrive nightdrive.tail1.ts.net"))
        #expect(await fake.forgotten == ["studio"])
    }
}
