import Foundation
import Synchronization
@testable import FerryServer

enum Fixture {
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
    }
}

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let t: Mutex<TimeInterval>
    init(_ start: TimeInterval = 1_800_000_000) { t = Mutex(start) }
    var now: TimeInterval { t.withLock { $0 } }
    func advance(_ s: TimeInterval) { t.withLock { $0 += s } }
    var function: @Sendable () -> TimeInterval { { self.now } }
}

/// Tailscale's command as a test wants it: a status, a serve status, and what `serve` was asked.
actor FakeTailscale: TailscaleCLI {
    var statusData: Data?
    var serveData = Data("{}".utf8)
    var serveAnswer = (ok: true, output: "")
    private(set) var statusCalls = 0
    private(set) var serveCalls: [(on: Bool, port: UInt16)] = []

    init(_ fixture: String = "tailscale-status") {
        statusData = try? Fixture.data(fixture)
    }

    func set(status: Data?) { statusData = status }
    func set(serve: Data) { serveData = serve }

    func status() async throws -> Data {
        statusCalls += 1
        guard let statusData else { throw URLError(.cannotConnectToHost) }
        return statusData
    }

    func serveStatus() async throws -> Data { serveData }

    /// Like tailscale serve: when it succeeds, serve status shows the proxy afterwards
    func serve(on: Bool, port: UInt16) async -> (ok: Bool, output: String) {
        serveCalls.append((on, port))
        if serveAnswer.ok {
            serveData = on ? Data(#"{"Web":{"macbook.tail1234.ts.net:443":{"Handlers":{"/ferry":{"Proxy":"http://127.0.0.1:\#(port)"}}}}}"#.utf8)
                : Data("{}".utf8)
        }
        return serveAnswer
    }

    func set(serveAnswer: (ok: Bool, output: String)) { self.serveAnswer = serveAnswer }
}

func tempFolder() -> URL {
    let u = FileManager.default.temporaryDirectory.appending(path: "ferry-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Requests to other computers and to push services, recorded; each host answers with the status set for it (201 by
/// default), or fails when it is in `down`.
actor FakeOutbound: Outbound {
    struct Sent: Sendable { let request: URLRequest; let body: Data; let file: URL? }
    private(set) var sent: [Sent] = []
    var statusByHost: [String: Int] = [:]
    var answerByHost: [String: Data] = [:]
    var down: Set<String> = []

    func set(status: Int, for host: String) { statusByHost[host] = status }
    func set(answer: Data, for host: String) { answerByHost[host] = answer }
    func set(down host: String) { down.insert(host) }

    private func answer(_ request: URLRequest) throws -> (status: Int, body: Data) {
        let host = request.url?.host() ?? ""
        if down.contains(host) { throw URLError(.timedOut) }
        return (statusByHost[host] ?? 201, answerByHost[host] ?? Data())
    }

    func data(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        sent.append(Sent(request: request, body: request.httpBody ?? Data(), file: nil))
        return try answer(request)
    }

    /// Reports half the file sent, then all of it
    func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws
        -> (status: Int, body: Data) {
        sent.append(Sent(request: request, body: (try? Data(contentsOf: file)) ?? Data(), file: file))
        progress(0.5)
        progress(1)
        return try answer(request)
    }
}

/// The Mac's side of things as a test sees it: a name, how long since input, a Downloads folder, the clipboard and
/// notifications, recorded.
actor FakeSystem: FerrySystem {
    nonisolated let downloads: URL
    var seconds: Int? = 12
    /// freeSpace is synchronous (it is asked before an upload starts), so its value lives outside the actor
    nonisolated let free = Mutex<Int64?>(100 << 30)
    private(set) var clipboardText: String?
    private(set) var clipboardImage: (URL, String)?
    /// Whether the last copy was marked for clipboard histories to leave out
    private(set) var clipboardSensitive: Bool?
    private(set) var notices: [Notice] = []

    init(downloads: URL = tempFolder()) {
        self.downloads = downloads
    }

    func set(seconds: Int?) { self.seconds = seconds }
    nonisolated func set(free: Int64?) { self.free.withLock { $0 = free } }

    func computerName() async -> String { "MacBook" }
    func secondsSinceInput() async -> Int? { seconds }
    nonisolated func freeSpace(at: URL) -> Int64? { free.withLock { $0 } }
    func copy(text: String, sensitive: Bool) async { (clipboardText, clipboardSensitive) = (text, sensitive) }
    func copy(imageAt url: URL, type: String, sensitive: Bool) async { (clipboardImage, clipboardSensitive) = ((url, type), sensitive) }
    func notify(_ notice: Notice) async { notices.append(notice) }

}
