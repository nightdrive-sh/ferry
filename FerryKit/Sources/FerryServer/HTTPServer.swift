import Foundation
import Network
import Synchronization

/// A request's body as it arrives, never all in memory unless asked (`collect`): a 4 GiB upload streams to disk.
public final class HTTPBody: Sendable {
    static let chunk = 1 << 20

    private let pull: @Sendable () async throws -> Data?
    private let state: Mutex<Bool>

    /// pull gives the next piece, nil at the end
    public init(pull: @escaping @Sendable () async throws -> Data?) {
        self.pull = pull
        state = Mutex(false)
    }

    public convenience init(data: Data) {
        let left = Mutex(data.isEmpty ? nil : data)
        self.init { left.withLock { d in defer { d = nil }; return d } }
    }

    public static var empty: HTTPBody {
        let b = HTTPBody { nil }
        b.state.withLock { $0 = true }
        return b
    }

    /// Whether the end was read. A response to a request whose body wasn't must close the connection: the rest of the
    /// body would otherwise be read as the next request.
    public var consumed: Bool { state.withLock { $0 } }

    public func next() async throws -> Data? {
        if consumed { return nil }
        let d = try await pull()
        if d == nil { state.withLock { $0 = true } }
        return d
    }

    public func collect(limit: Int) async throws -> Data {
        var out = Data()
        while let d = try await next() {
            out.append(d)
            if out.count > limit { throw HTTPError.tooBig }
        }
        return out
    }
}

public struct HTTPRequest: Sendable {
    public var head: HTTPHead
    public var body: HTTPBody

    public init(head: HTTPHead, body: HTTPBody = .empty) {
        self.head = head
        self.body = body
    }

    public var method: String { head.method }
    public var path: String { head.path }
    public var query: [String: String] { head.query }
    public var headers: HTTPHeaders { head.headers }
}

/// HTTP/1.1 on 127.0.0.1 only. `tailscale serve` keeps its connection open and sends request after request on it.
public actor HTTPServer {
    private let port: UInt16
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "fi.feature.ferry.server")

    public init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    /// Starts listening and returns the port it got (the one asked for, or any free one for 0).
    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return conn.cancel() }
            Task { await self.serve(conn) }
        }
        let started = Mutex<CheckedContinuation<UInt16, any Error>?>(nil)
        return try await withCheckedThrowingContinuation { cont in
            started.withLock { $0 = cont }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    started.withLock { $0?.resume(returning: listener.port?.rawValue ?? 0); $0 = nil }
                case .failed(let error):
                    started.withLock { $0?.resume(throwing: error); $0 = nil }
                case .cancelled:
                    started.withLock { $0?.resume(throwing: CancellationError()); $0 = nil }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
    }

    private func serve(_ conn: NWConnection) async {
        connections[ObjectIdentifier(conn)] = conn
        defer {
            conn.cancel()
            connections[ObjectIdentifier(conn)] = nil
        }
        conn.start(queue: queue)
        let reader = ConnectionReader(conn)
        let handler = self.handler
        while true {
            let head: HTTPHead
            let framing: BodyFraming
            do {
                guard let h = try await reader.head() else { return }
                head = h
                framing = try h.framing
            } catch {
                _ = try? await reader.write(HTTPResponse.text(400, "Bad request"), close: true, headOnly: false)
                return
            }
            await reader.startBody(framing)
            let body = framing == .none ? HTTPBody.empty : HTTPBody { try await reader.nextBody() }
            let response = await handler(HTTPRequest(head: head, body: body))
            let close = !body.consumed || head.headers["Connection"]?.lowercased() == "close"
            do {
                try await reader.write(response, close: close, headOnly: head.method == "HEAD")
            } catch {
                return
            }
            if close { return }
        }
    }
}

/// One connection's bytes: the buffer a head is parsed from, and the body read after it.
actor ConnectionReader {
    private let conn: NWConnection
    private var buffer = Data()
    private var eof = false
    private var framing = BodyFraming.none
    private var left: Int64 = 0
    private var chunked = ChunkedDecoder()
    private var bodyDone = true

    init(_ conn: NWConnection) {
        self.conn = conn
    }

    /// More bytes into the buffer; false at the end of the connection.
    private func more() async throws -> Bool {
        if eof { return false }
        let (data, complete) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), any Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: HTTPBody.chunk) { data, _, complete, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data, complete)) }
            }
        }
        if let data { buffer.append(data) }
        if complete { eof = true }
        return data?.isEmpty == false
    }

    /// The next request's head; nil when the connection ended between requests.
    func head() async throws -> HTTPHead? {
        while true {
            if let (head, n) = try HTTPHead.parse(buffer) {
                buffer.removeFirst(n)
                return head
            }
            guard try await more() else {
                if buffer.isEmpty { return nil }
                throw HTTPError.malformed
            }
        }
    }

    func startBody(_ f: BodyFraming) {
        framing = f
        chunked = ChunkedDecoder()
        switch f {
        case .none: bodyDone = true
        case .length(let n): left = n; bodyDone = false
        case .chunked: bodyDone = false
        }
    }

    func nextBody() async throws -> Data? {
        while !bodyDone {
            if buffer.isEmpty, !(try await more()) {
                throw URLError(.networkConnectionLost)   // the client went away mid-body
            }
            switch framing {
            case .length:
                let n = min(Int64(buffer.count), left, Int64(HTTPBody.chunk))
                let piece = buffer.prefix(Int(n))
                buffer.removeFirst(Int(n))
                left -= n
                if left == 0 { bodyDone = true }
                return Data(piece)
            case .chunked:
                let r = try chunked.feed(buffer.prefix(HTTPBody.chunk))
                buffer.removeFirst(r.consumed)
                if r.done { bodyDone = true }
                if !r.bytes.isEmpty { return r.bytes }
            case .none:
                bodyDone = true
            }
        }
        return nil
    }

    func write(_ response: HTTPResponse, close: Bool, headOnly: Bool) async throws {
        try await send(response.head(close: close))
        guard !headOnly else { return }
        switch response.body {
        case .data(let d):
            if !d.isEmpty { try await send(d) }
        case .file(let url, _):
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            while let d = try h.read(upToCount: HTTPBody.chunk), !d.isEmpty {
                try await send(d)
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }
}
