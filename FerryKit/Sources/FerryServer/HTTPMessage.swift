import Foundation

/// The little of HTTP/1.1 Ferry needs. Its only client is `tailscale serve` on localhost (and other computers' Ferry
/// through it), so this reads requests and writes responses without a library.
public enum HTTPError: Error, Equatable {
    case malformed
    case tooBig
}

/// A request's headers. Names are case-insensitive, and the first value of a repeated one wins.
public struct HTTPHeaders: Sendable, Equatable {
    public private(set) var fields: [(name: String, value: String)]

    public init(_ fields: [(name: String, value: String)] = []) {
        self.fields = fields
    }

    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public static func == (a: HTTPHeaders, b: HTTPHeaders) -> Bool {
        a.fields.elementsEqual(b.fields) { $0.name == $1.name && $0.value == $1.value }
    }
}

/// How a request's body is delimited.
public enum BodyFraming: Equatable, Sendable {
    case none
    case length(Int64)
    case chunked
}

public struct HTTPHead: Sendable, Equatable {
    /// Past this, a head that hasn't ended is refused rather than buffered
    static let maxLength = 64 * 1024

    public var method: String
    /// The path as sent, without the query
    public var path: String
    /// Percent-decoded, `+` as a space, as Python's parse_qsl gives bin/ferry
    public var query: [String: String]
    public var headers: HTTPHeaders

    public init(method: String, path: String, query: [String: String] = [:], headers: HTTPHeaders = HTTPHeaders()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
    }

    /// The head at the start of buffer, and how many bytes it took; nil until it has all arrived.
    public static func parse(_ buffer: Data) throws(HTTPError) -> (head: HTTPHead, length: Int)? {
        let buffer = Data(buffer)   // a slice's indices don't start at 0
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maxLength { throw .tooBig }
            return nil
        }
        guard end.lowerBound <= maxLength, let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
            throw end.lowerBound > maxLength ? .tooBig : .malformed
        }
        var lines = text.components(separatedBy: "\r\n")
        let request = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard request.count == 3, request[2].hasPrefix("HTTP/1."), request[1].hasPrefix("/") else { throw .malformed }
        var fields: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw .malformed }
            fields.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                           String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        let target = request[1]
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = path.count > 1 ? Self.query(String(path[1])) : [:]
        return (HTTPHead(method: String(request[0]), path: String(path[0]), query: query, headers: HTTPHeaders(fields)),
                end.upperBound)
    }

    static func query(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            let key = decode(kv[0])
            if out[key] == nil {   // parse_qsl into a dict keeps the last; Ferry never repeats a key, so either is fine
                out[key] = kv.count > 1 ? decode(kv[1]) : ""
            }
        }
        return out
    }

    public var framing: BodyFraming {
        get throws(HTTPError) {
            if let te = headers["Transfer-Encoding"], te.lowercased().contains("chunked") { return .chunked }
            guard let cl = headers["Content-Length"] else { return .none }
            guard let n = Int64(cl), n >= 0 else { throw .malformed }
            return n == 0 ? .none : .length(n)
        }
    }
}

/// A chunked body taken apart as its bytes arrive, in whatever pieces the connection gives them.
public struct ChunkedDecoder: Sendable {
    private enum State { case size, data(Int), dataEnd, trailer, done }
    private var state = State.size
    private var line = Data()

    public init() {}

    /// The body's bytes in data, whether the body has ended, and how many of data's bytes it took: the ones after the
    /// end belong to the next request on the connection.
    public mutating func feed(_ data: Data) throws(HTTPError) -> (bytes: Data, done: Bool, consumed: Int) {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex {
            switch state {
            case .done:
                return (out, true, i - data.startIndex)
            case .data(let left):
                let n = min(left, data.endIndex - i)
                out.append(data[i..<(i + n)])
                i += n
                state = left == n ? .dataEnd : .data(left - n)
            case .size, .dataEnd, .trailer:
                let byte = data[i]
                i += 1
                guard byte == UInt8(ascii: "\n") else {
                    line.append(byte)
                    if line.count > 1024 { throw .malformed }
                    continue
                }
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll()
                switch state {
                case .size:
                    let hex = text.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    guard let size = Int(hex, radix: 16), size >= 0 else { throw .malformed }
                    state = size == 0 ? .trailer : .data(size)
                case .dataEnd:
                    guard text.isEmpty else { throw .malformed }
                    state = .size
                default:   // trailer lines until an empty one
                    if text.isEmpty { state = .done }
                }
            }
        }
        if case .done = state { return (out, true, i - data.startIndex) }
        return (out, false, i - data.startIndex)
    }
}

public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        /// A file sent in pieces, never read whole
        case file(URL, length: Int64)
    }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Body

    public init(status: Int, headers: [(String, String)] = [], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: .data(body))
    }

    /// An error or a message, plain text written for a person to read (docs/protocol.md › Calls)
    public static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: .data(Data(message.utf8)))
    }

    var length: Int64 {
        switch body {
        case .data(let d): Int64(d.count)
        case .file(_, let n): n
        }
    }

    static let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                          413: "Content Too Large", 500: "Internal Server Error", 507: "Insufficient Storage"]

    /// The status line and headers; close also says the connection ends after this response.
    public func head(close: Bool) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        for (k, v) in headers where k.caseInsensitiveCompare("Content-Length") != .orderedSame {
            s += "\(k): \(v)\r\n"
        }
        s += "Content-Length: \(length)\r\n"
        if close { s += "Connection: close\r\n" }
        return Data((s + "\r\n").utf8)
    }
}
