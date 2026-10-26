import Foundation
import Network
import Synchronization
import Testing
@testable import FerryServer

/// Bytes to a port and whatever comes back until the server closes the connection (or the wait runs out), for the
/// cases URLSession hides: keep-alive, chunked bodies, a connection the server ends.
enum RawClient {
    struct Answer { let data: Data; let closed: Bool }

    static func exchange(_ bytes: Data, host: String = "127.0.0.1", port: UInt16, wait: Duration = .seconds(3)) async throws -> Answer {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let got = Mutex<(data: Data, closed: Bool, failed: Bool)>((Data(), false, false))
        let queue = DispatchQueue(label: "raw-client")
        conn.stateUpdateHandler = { state in
            if case .failed = state { got.withLock { $0.failed = true } }
            if case .waiting = state { got.withLock { $0.failed = true } }
        }
        conn.start(queue: queue)
        conn.send(content: bytes, completion: .contentProcessed { _ in })
        @Sendable func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                got.withLock {
                    if let data { $0.data.append(data) }
                    if complete || error != nil { $0.closed = true }
                }
                if !(complete || error != nil) { receive() }
            }
        }
        receive()
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline, !got.withLock({ $0.closed || $0.failed }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        conn.cancel()
        let r = got.withLock { $0 }
        if r.failed && r.data.isEmpty { throw URLError(.cannotConnectToHost) }
        return Answer(data: r.data, closed: r.closed)
    }
}

@Suite struct HTTPServerTests {
    func server(_ handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) async throws -> (HTTPServer, UInt16) {
        let s = HTTPServer(port: 0, handler: handler)
        return (s, try await s.start())
    }

    @Test func answersAndKeepsAlive() async throws {
        let (s, port) = try await server { .text(200, $0.path) }
        defer { Task { await s.stop() } }
        // Two requests on one connection: the second is answered after the first
        let a = try await RawClient.exchange(Data("GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n".utf8),
                                             port: port, wait: .milliseconds(800))
        let text = String(decoding: a.data, as: UTF8.self)
        #expect(text.components(separatedBy: "HTTP/1.1 200 OK").count == 3)
        #expect(text.hasSuffix("\r\n\r\n/b"))
        #expect(!a.closed)   // kept alive
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/c")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "/c")
    }

    @Test func streamsABigBody() async throws {
        let biggest = Mutex(0)
        let (s, port) = try await server { req in
            var n = 0
            while let chunk = try? await req.body.next() {
                n += chunk.count
                biggest.withLock { $0 = max($0, chunk.count) }
            }
            return .text(200, String(n))
        }
        defer { Task { await s.stop() } }
        let file = FileManager.default.temporaryDirectory.appending(path: "ferry-big-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let h = try FileHandle(forWritingTo: file)
        for _ in 0..<64 { h.write(Data(repeating: 7, count: 1 << 20)) }
        try h.close()
        defer { try? FileManager.default.removeItem(at: file) }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/upload")!)
        req.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.upload(for: req, fromFile: file)
        #expect(String(decoding: data, as: UTF8.self) == "67108864")
        #expect(biggest.withLock { $0 } <= 1 << 20)
    }

    @Test func unreadBodyClosesTheConnection() async throws {   // Review Focus 1
        let (s, port) = try await server { _ in .text(403, "No") }
        defer { Task { await s.stop() } }
        let a = try await RawClient.exchange(Data("POST /api/upload HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n0123456789".utf8),
                                             port: port)
        let text = String(decoding: a.data, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(a.closed)
    }

    @Test func chunkedUpload() async throws {
        let (s, port) = try await server { req in
            .text(200, String(decoding: (try? await req.body.collect(limit: 100)) ?? Data("failed".utf8), as: UTF8.self))
        }
        defer { Task { await s.stop() } }
        let a = try await RawClient.exchange(Data(("POST /api/upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\nGET /next HTTP/1.1\r\nHost: x\r\n\r\n").utf8), port: port, wait: .milliseconds(800))
        let text = String(decoding: a.data, as: UTF8.self)
        #expect(text.contains("\r\n\r\nhelloworld"))
        // The bytes after the chunked body are the next request, answered on the same connection
        #expect(text.components(separatedBy: "HTTP/1.1 200 OK").count == 3)
        #expect(!a.closed)
    }

    @Test func tooBigBodyStopsAtTheLimit() async throws {
        let (s, port) = try await server { req in
            do { _ = try await req.body.collect(limit: 4); return .text(200, "read") } catch { return .text(400, "Bad request") }
        }
        defer { Task { await s.stop() } }
        let a = try await RawClient.exchange(Data("POST /api/text HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789".utf8),
                                             port: port, wait: .milliseconds(800))
        #expect(String(decoding: a.data, as: UTF8.self).hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }

    @Test func onlyLocalhost() async throws {
        guard let other = Self.nonLoopbackIPv4() else { return }
        let (s, port) = try await server { _ in .text(200, "here") }
        defer { Task { await s.stop() } }
        let reached = try? await RawClient.exchange(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8), host: other, port: port,
                                                    wait: .seconds(1))
        #expect(reached == nil || reached?.data.isEmpty == true)
    }

    static func nonLoopbackIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let s = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !s.hasPrefix("127.") { return s }
        }
        return nil
    }
}
