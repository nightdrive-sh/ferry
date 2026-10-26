import Foundation
import Synchronization
import Testing
@testable import FerryKit

/// Answers HTTPBackend's requests in place of the network, and keeps what it was asked.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { let request: URLRequest; let body: Data }
    enum Reply: Sendable { case http(Int, Data), fail(URLError.Code) }

    static let state = Mutex<(reply: Reply, seen: [Seen])>((.http(200, Data()), []))

    static func reply(_ r: Reply) { state.withLock { $0 = (r, []) } }
    static var seen: [Seen] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {   // uploads arrive as a stream
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let req = request
        let reply = Self.state.withLock { s in
            s.seen.append(Seen(request: req, body: body))
            return s.reply
        }
        switch reply {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let data):
            let r = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

let machine = URL(string: "https://nightdrive.tail1.ts.net/ferry/")!

func backend() -> HTTPBackend {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubProtocol.self]
    return HTTPBackend(configuration: c)
}

func json(_ s: String) -> Data { Data(s.utf8) }

@Suite(.serialized) struct HTTPBackendTests {
    @Test func everyRequestHasFerryHeader() async throws {
        let b = backend()
        StubProtocol.reply(.http(200, json(#"{"computer":"Nightdrive"}"#)))
        _ = try await b.ping(machine)
        StubProtocol.reply(.http(200, json(#"{"computer":"N","items":[],"keep":7,"idle":0}"#)))
        _ = try await b.items(machine)
        StubProtocol.reply(.http(200, json(#"{"machines":[]}"#)))
        _ = try await b.machines(machine)
        StubProtocol.reply(.http(200, json(#"{"ok":true}"#)))
        try await b.remove("abc", on: machine)
        let all = StubProtocol.seen
        #expect(!all.isEmpty)
        for s in all { #expect(s.request.value(forHTTPHeaderField: "X-Ferry") == "1") }
        #expect(all.last?.request.url?.absoluteString == "https://nightdrive.tail1.ts.net/ferry/api/remove?id=abc")
        #expect(all.last?.request.httpMethod == "POST")
    }

    @Test func pingReturnsName() async throws {
        StubProtocol.reply(.http(200, json(#"{"computer":"Nightdrive"}"#)))
        #expect(try await backend().ping(machine) == "Nightdrive")
        #expect(StubProtocol.seen.first?.request.url?.absoluteString == "https://nightdrive.tail1.ts.net/ferry/api/ping")
    }

    @Test func textBodyAndClip() async throws {
        StubProtocol.reply(.http(200, json(#"{"ok":true}"#)))
        try await backend().send(.text("801566", clip: true), to: machine, progress: { _ in })
        let s = try #require(StubProtocol.seen.first)
        #expect(s.request.httpMethod == "POST")
        #expect(s.request.url?.absoluteString == "https://nightdrive.tail1.ts.net/ferry/api/text")
        #expect(s.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: s.body) as? [String: Any])
        #expect(body["text"] as? String == "801566")
        #expect(body["clip"] as? Bool == true)
    }

    @Test func uploadQueryIsEncoded() async throws {
        let name = "Lasku & kuitti #2 +ä.pdf"
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("pdf bytes".utf8).write(to: file)
        StubProtocol.reply(.http(200, json(#"{"ok":true,"name":"x"}"#)))
        try await backend().send(.file(file, name: name, type: "application/pdf", clip: false), to: machine, progress: { _ in })
        let s = try #require(StubProtocol.seen.first)
        let url = try #require(s.request.url)
        #expect(url.path() == "/ferry/api/upload")
        let raw = try #require(url.query(percentEncoded: true))
        // The value's own & + # are escaped: the raw query splits into exactly two pairs
        #expect(raw.split(separator: "&").count == 2)
        #expect(!raw.contains("+"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "name" }?.value == name)
        #expect(items.first { $0.name == "type" }?.value == "application/pdf")
        #expect(!items.contains { $0.name == "clip" })
        #expect(s.body == Data("pdf bytes".utf8))
    }

    @Test func uploadClipImage() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([0x89, 0x50]).write(to: file)
        StubProtocol.reply(.http(200, json(#"{"ok":true,"name":"x"}"#)))
        try await backend().send(.file(file, name: "clipboard.png", type: "image/png", clip: true), to: machine, progress: { _ in })
        let url = try #require(StubProtocol.seen.first?.request.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "clip" }?.value == "1")
    }

    @Test func refusedCarriesServerText() async throws {
        StubProtocol.reply(.http(404, json("Not in the box any more")))
        await #expect(throws: FerryError.refused(status: 404, message: "Not in the box any more")) {
            try await backend().remove("gone", on: machine)
        }
    }

    @Test func timeoutIsUnreachable() async throws {
        StubProtocol.reply(.fail(.timedOut))
        await #expect(throws: FerryError.unreachable(machine: "nightdrive", timedOut: true)) {
            _ = try await backend().items(machine)
        }
    }

    // An answer that is no (no such name, nothing listening) is told from no answer yet: setup waits only for the latter
    @Test func otherFailuresAreUnreachableAtOnce() async throws {
        for code in [URLError.Code.cannotFindHost, .cannotConnectToHost, .notConnectedToInternet] {
            StubProtocol.reply(.fail(code))
            await #expect(throws: FerryError.unreachable(machine: "nightdrive", timedOut: false)) {
                _ = try await backend().ping(machine)
            }
        }
    }

    @Test func machinesUsesLongTimeout() async throws {
        StubProtocol.reply(.http(200, json(#"{"machines":[]}"#)))
        _ = try await backend().machines(machine)
        #expect(StubProtocol.seen.first?.request.timeoutInterval == 15)
        StubProtocol.reply(.http(200, json(#"{"computer":"N","items":[],"keep":7}"#)))
        _ = try await backend().items(machine)
        #expect(StubProtocol.seen.first?.request.timeoutInterval == 8)
    }

    @Test func forgetPostsTheDevice() async throws {
        StubProtocol.reply(.http(200, json(#"{"ok":true}"#)))
        try await backend().forget("macbook", on: machine)
        let seen = try #require(StubProtocol.seen.first)
        #expect(seen.request.url?.absoluteString == "https://nightdrive.tail1.ts.net/ferry/api/forget")
        #expect(seen.request.httpMethod == "POST")
        #expect(seen.request.value(forHTTPHeaderField: "X-Ferry") == "1")
        #expect(try JSONSerialization.jsonObject(with: seen.body) as? [String: String] == ["device": "macbook"])
    }

    @Test func clearReceivedClearsThePhonesSide() async throws {
        StubProtocol.reply(.http(200, json(#"{"ok":true}"#)))
        try await backend().clearReceived(on: machine)
        #expect(StubProtocol.seen.first?.request.url?.absoluteString == "https://nightdrive.tail1.ts.net/ferry/api/clear?to=phone")
    }

    @Test func downloadKeepsName() async throws {
        let item = try JSONDecoder().decode(Item.self, from: json(
            #"{"id":"3cbf3529eee7","to":"phone","kind":"file","time":1,"name":"night-waves.png","size":3,"type":"image/png"}"#))
        StubProtocol.reply(.http(200, Data([1, 2, 3])))
        let file = try await backend().download(item, from: machine)
        #expect(file.lastPathComponent == "night-waves.png")
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        #expect(StubProtocol.seen.first?.request.url?.absoluteString == "https://nightdrive.tail1.ts.net/ferry/api/file/3cbf3529eee7")
        #expect(StubProtocol.seen.first?.request.timeoutInterval == 120)
    }

    @Test func cancellationIsNotUnreachable() async throws {   // review 1: leaving the foreground cancels a poll
        StubProtocol.reply(.fail(.cancelled))
        await #expect(throws: CancellationError.self) { _ = try await backend().items(machine) }
    }

    @Test func uploadUsesTheShortIdleTimeout() async throws {   // review 3: an unanswered connect fails in 8 s, not 60
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([1]).write(to: file)
        StubProtocol.reply(.http(200, json(#"{"ok":true,"name":"x"}"#)))
        try await backend().send(.file(file, name: "a.png", type: "image/png", clip: true), to: machine, progress: { _ in })
        #expect(StubProtocol.seen.first?.request.timeoutInterval == 8)
    }

    @Test func askTimeoutIsTheOneGiven() async throws {   // the share sheet asks with a short wait
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        StubProtocol.reply(.http(200, json(#"{"computer":"N","items":[],"keep":7,"idle":0}"#)))
        _ = try await HTTPBackend(configuration: c, timeout: 2.5).items(machine)
        #expect(StubProtocol.seen.first?.request.timeoutInterval == 2.5)
    }

    @Test func uploadRequestOnItsOwn() throws {   // the share extension's background session builds it without send()
        let req = HTTPBackend.uploadRequest(machine, name: "Lasku & kuitti #2.pdf", type: "application/pdf", clip: false)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "X-Ferry") == "1")
        let url = try #require(req.url)
        #expect(url.path().hasSuffix("/ferry/api/upload"))
        #expect(url.query(percentEncoded: true) == "name=Lasku%20%26%20kuitti%20%232.pdf&type=application/pdf")
        #expect(req.timeoutInterval == 8)
    }
}
