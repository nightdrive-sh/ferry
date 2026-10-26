import Foundation
import Testing
@testable import FerryServer

@Suite struct HTTPMessageTests {
    @Test func parsesHeadInPieces() throws {
        let raw = Data(("POST /ferry/api/upload?name=Lasku%20%26%20kuitti%20%232.pdf&type=application/pdf HTTP/1.1\r\n"
            + "Host: macbook.tail1234.ts.net\r\nContent-Length: 5\r\n\r\nhello").utf8)
        #expect(try HTTPHead.parse(raw.prefix(20)) == nil)
        let (head, length) = try #require(try HTTPHead.parse(raw))
        #expect(head.method == "POST")
        #expect(head.path == "/ferry/api/upload")
        #expect(head.query["name"] == "Lasku & kuitti #2.pdf")
        #expect(head.query["type"] == "application/pdf")
        #expect(head.headers["content-length"] == "5")
        #expect(head.headers["HOST"] == "macbook.tail1234.ts.net")
        #expect(try head.framing == .length(5))
        #expect(raw[length...] == Data("hello".utf8))
    }

    @Test func plusInTheQueryIsASpace() throws {
        let (head, _) = try #require(try HTTPHead.parse(Data("GET /api/clear?to=phone&x=a+b HTTP/1.1\r\n\r\n".utf8)))
        #expect(head.query == ["to": "phone", "x": "a b"])
        #expect(try head.framing == BodyFraming.none)
    }

    @Test func chunkedFraming() throws {
        let (head, _) = try #require(try HTTPHead.parse(Data("POST /api/upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        #expect(try head.framing == .chunked)
        var d = ChunkedDecoder()
        let a = try d.feed(Data("5\r\nhel".utf8))
        #expect(a.bytes == Data("hel".utf8))
        #expect(!a.done)
        let b = try d.feed(Data("lo\r\n0\r\n\r\n".utf8))
        #expect(b.bytes == Data("lo".utf8))
        #expect(b.done)
    }

    @Test func chunkExtensionIgnored() throws {
        var d = ChunkedDecoder()
        let r = try d.feed(Data("5;x=y\r\nhello\r\n0\r\n\r\nGET".utf8))
        #expect(r.bytes == Data("hello".utf8))
        #expect(r.done)
        #expect(r.consumed == 19)   // "GET" is the next request's
    }

    @Test func malformedHeadThrows() {
        #expect(throws: HTTPError.malformed) { try HTTPHead.parse(Data("GARBAGE\r\n\r\n".utf8)) }
        #expect(throws: HTTPError.tooBig) { try HTTPHead.parse(Data(repeating: UInt8(ascii: "a"), count: 70_000)) }
        var d = ChunkedDecoder()
        #expect(throws: HTTPError.malformed) { try d.feed(Data("zz\r\n".utf8)) }
    }

    @Test func responseHead() {
        let head = String(decoding: HTTPResponse.text(404, "Not found").head(close: true), as: UTF8.self)
        #expect(head.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(head.contains("Content-Length: 9\r\n"))
        #expect(head.contains("Content-Type: text/plain; charset=utf-8\r\n"))
        #expect(head.contains("Connection: close\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
        #expect(!String(decoding: HTTPResponse.text(200, "x").head(close: false), as: UTF8.self).contains("Connection"))
    }

    @Test func jsonResponse() throws {
        let r = HTTPResponse.json(["ok": true])
        #expect(r.status == 200)
        #expect(r.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/json" })
        guard case .data(let body) = r.body else { Issue.record("not data"); return }
        #expect(String(decoding: body, as: UTF8.self) == #"{"ok":true}"#)
    }
}
