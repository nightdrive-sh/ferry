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
    /// What each send carried, and where
    private(set) var sent: [(payload: SendPayload, to: URL)] = []
    /// Computers that answer a send with this refusal (no room)
    var refusing: [URL: FerryError] = [:]
    func setRefusing(_ url: URL, _ e: FerryError?) { refusing[url] = e }
    func send(_ payload: SendPayload, to machine: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try check(machine, "send")
        if let e = refusing[machine] { throw e }
        sent.append((payload, machine))
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
           cache: FileCache? = nil, defaults: UserDefaults? = nil, clock: TestClock? = nil,
           queue: SendQueue? = nil) throws -> FerryModel {
    let defaults = try defaults ?? #require(UserDefaults(suiteName: UUID().uuidString))
    var list = MachineList()
    for (i, (url, name)) in machines.enumerated() { list.add(url, name: name, at: t0, asSetup: i == 0) }
    let store = MachineStore(defaults: defaults)
    store.save(list)
    return FerryModel(backend: fake, store: store, now: { clock?.now ?? t0 }, sentHold: .milliseconds(20), cache: cache,
                      wakeRetry: .milliseconds(20), queue: queue)
}

func tempCache() -> FileCache {
    FileCache(directory: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)"))
}
