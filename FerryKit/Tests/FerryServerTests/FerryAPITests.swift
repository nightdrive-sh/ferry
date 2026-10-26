import FerryKit
import Foundation
import Synchronization
import Testing
@testable import FerryServer

/// A FerryAPI on the Task 3 fixture's tailnet, with a fake Mac, and requests as the owner's iPhone sends them.
struct APIRig {
    let state = tempFolder()
    let system = FakeSystem()
    let clock = TestClock()
    let outbound = FakeOutbound()
    let box: Box
    let pusher: Pusher
    let forgotten: Forgotten
    let api: FerryAPI

    init() throws {
        var config = ServerConfig(state: state)
        config.port = 0
        box = Box(state: state, keepDays: 7, clock: clock.function)
        pusher = Pusher(state: state, key: try VAPIDKey.load(orCreateIn: state), config: config, outbound: outbound)
        forgotten = Forgotten(state: state, clock: clock.function)
        api = FerryAPI(config: config, system: system, tailnet: Tailnet(cli: FakeTailscale(), clock: clock.function),
                       box: box, pusher: pusher, forgotten: forgotten, clock: clock.function,
                       machines: { [["url": .string("https://macbook.tail1234.ts.net/ferry/"), "name": .string("MacBook"), "self": .bool(true)]] })
    }

    static let iphone: [(String, String)] = [("Host", "macbook.tail1234.ts.net"), ("Tailscale-User-Login", "jari@example.com"),
                                             ("X-Ferry", "1"), ("X-Forwarded-For", "100.64.0.4")]

    func request(_ method: String, _ target: String, headers: [(String, String)] = iphone, replacing: [(String, String?)] = [],
                 body: HTTPBody = .empty) -> HTTPRequest {
        var fields = headers
        for (name, value) in replacing {
            fields.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            if let value { fields.append((name, value)) }
        }
        let parts = target.split(separator: "?", maxSplits: 1)
        return HTTPRequest(head: HTTPHead(method: method, path: String(parts[0]),
                                          query: parts.count > 1 ? HTTPHead.query(String(parts[1])) : [:],
                                          headers: HTTPHeaders(fields.map { (name: $0.0, value: $0.1) })),
                           body: body)
    }

    func call(_ method: String, _ target: String, json: String? = nil, replacing: [(String, String?)] = [],
              body: HTTPBody? = nil) async -> HTTPResponse {
        await api.handle(request(method, target, replacing: replacing,
                                 body: body ?? json.map { HTTPBody(data: Data($0.utf8)) } ?? .empty))
    }
}

extension HTTPResponse {
    var bodyText: String {
        if case .data(let d) = body { return String(decoding: d, as: UTF8.self) }
        return ""
    }
    var json: [String: Any] {
        guard case .data(let d) = body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

@Suite struct FerryAPITests {
    static let gateCopy = "Ferry answers only its computer's owner, through Tailscale."

    // MARK: The gate

    @Test func gateRejectsStrangers() async throws {
        let r = try APIRig()
        let stranger = await r.call("GET", "/api/items", replacing: [("Tailscale-User-Login", "other@example.com")])
        #expect(stranger.status == 403)
        #expect(stranger.bodyText == Self.gateCopy)
        #expect(await r.call("GET", "/api/items", replacing: [("Tailscale-User-Login", nil)]).status == 403)
        #expect(await r.call("GET", "/api/items", replacing: [("Host", "127.0.0.1:47270")]).status == 403)
        let noHeader = await r.call("GET", "/api/items", replacing: [("X-Ferry", nil)])
        #expect(noHeader.status == 403)
        #expect(noHeader.bodyText == "Not from the Ferry page")
        // A file link needs no X-Ferry (an <img> or a download can't send one), only the owner
        #expect(await r.call("GET", "/api/file/aaaaaaaaaaaa", replacing: [("X-Ferry", nil)]).bodyText == "Not in the box any more")
        #expect(await r.call("GET", "/ferry/api/ping").status == 200)   // the mount, should it come through
        #expect(await r.call("GET", "/api/items").header("Cache-Control") == "no-cache")
        #expect(await r.call("GET", "/api/items").header("X-Content-Type-Options") == "nosniff")
    }

    @Test func corsForTheOwnersPages() async throws {
        let r = try APIRig()
        let nd = "https://nightdrive.tail1234.ts.net"
        let page = await r.call("GET", "/api/items", replacing: [("Origin", nd), ("Sec-Fetch-Site", "cross-site")])
        #expect(page.status == 200)
        #expect(page.header("Access-Control-Allow-Origin") == nd)
        #expect(page.header("Vary") == "Origin")
        let other = await r.call("GET", "/api/items", replacing: [("Origin", "https://stranger.tail1234.ts.net"),
                                                                ("Sec-Fetch-Site", "cross-site")])
        #expect(other.status == 403)
        #expect(other.header("Access-Control-Allow-Origin") == nil)
        let pre = await r.call("OPTIONS", "/api/items", replacing: [("Origin", nd), ("X-Ferry", nil)])
        #expect(pre.status == 204)
        #expect(pre.header("Access-Control-Allow-Methods") == "GET, POST")
        #expect(pre.header("Access-Control-Allow-Headers") == "X-Ferry, Content-Type")
        #expect(pre.header("Access-Control-Max-Age") == "600")
        #expect(pre.header("Access-Control-Allow-Origin") == nd)
        let badPre = await r.call("OPTIONS", "/api/items", replacing: [("Origin", "https://stranger.tail1234.ts.net")])
        #expect(badPre.status == 403)
        #expect(badPre.bodyText == "Not allowed")
    }

    // MARK: Calls

    @Test func pingAndItems() async throws {
        let r = try APIRig()
        let ping = await r.call("GET", "/api/ping")
        #expect(ping.json["computer"] as? String == "MacBook")
        #expect((ping.json["idle"] as? NSNumber)?.intValue == 0)   // 12 s since input: in use
        await r.system.set(seconds: 300)
        #expect((await r.call("GET", "/api/ping").json["idle"] as? NSNumber)?.intValue == 300)
        await r.system.set(seconds: nil)
        #expect(await r.call("GET", "/api/ping").json["idle"] is NSNull)
        await r.box.append([BoxItem(id: "aaaaaaaaaaaa", to: "phone", kind: "text", time: r.clock.now, text: "for iphone", for: "iphone"),
                            BoxItem(id: "bbbbbbbbbbbb", to: "phone", kind: "text", time: r.clock.now, text: "for ipad", for: "ipad")])
        let items = await r.call("GET", "/api/items")
        #expect((items.json["items"] as? [[String: Any]])?.compactMap { $0["text"] as? String } == ["for iphone"])
        #expect((items.json["keep"] as? NSNumber)?.intValue == 7)
        #expect(items.json["push"] as? String == (await r.pusher.publicKey))
        // The answer decodes as the iPhone app reads it
        guard case .data(let d) = items.body else { Issue.record("no body"); return }
        #expect(try JSONDecoder().decode(ItemsResponse.self, from: d).items.count == 1)
        let machines = await r.call("GET", "/api/machines")
        #expect((machines.json["machines"] as? [[String: Any]])?.first?["self"] as? Bool == true)
    }

    /// docs/protocol.md › Codes and passwords: the Mac's own notification doesn't show one either (Notification
    /// Center keeps notifications, on disk too), and Copy still copies it
    @Test func aCodesNotificationHidesIt() async throws {
        let r = try APIRig()
        _ = await r.call("POST", "/api/text", json: #"{"text":"Tr0ub4dor&3"}"#)
        #expect(await r.system.notices.last?.title == "Text from iphone")
        #expect(await r.system.notices.last?.body == "Code or password · open to see")
        // Not the text either: Notification Center keeps a notification's info on disk. Its Copy reads the box.
        #expect(await r.system.notices.last?.text == nil)
        #expect(await r.system.notices.last?.item == (await r.box.items().last?.id))
        _ = await r.call("POST", "/api/text", json: #"{"text":"801566","clip":true}"#)
        #expect(await r.system.notices.last?.title == "Copied from iphone")
        #expect(await r.system.notices.last?.body == "Code or password")
        _ = await r.call("POST", "/api/text", json: #"{"text":"Milk, coffee"}"#)
        #expect(await r.system.notices.last?.body == "Milk, coffee")
        // The typed one waits for Copy, and the list says what it is; the one on the clipboard was copied: not kept
        let items = await r.call("GET", "/api/items")
        let listed = (items.json["items"] as? [[String: Any]]) ?? []
        #expect(listed.compactMap { $0["text"] as? String } == ["Tr0ub4dor&3", "Milk, coffee"])
        #expect(listed.map { $0["secret"] as? Bool } == [true, nil])
    }

    @Test func textWithAndWithoutClip() async throws {
        let r = try APIRig()
        let clip = await r.call("POST", "/api/text", json: #"{"text":"801566","clip":true}"#)
        #expect(clip.status == 200)
        #expect(clip.json["ok"] as? Bool == true)
        #expect(await r.system.clipboardText == "801566")
        #expect(await r.system.clipboardSensitive == true)   // kept out of clipboard histories (Maccy, Raycast)
        #expect(await r.system.notices.last?.title == "Copied from iphone")
        #expect(await r.system.notices.last?.copied == true)
        _ = await r.call("POST", "/api/text", json: #"{"text":"Milk, coffee"}"#)
        #expect(await r.system.clipboardText == "801566")   // a typed text waits for Copy
        #expect(await r.system.notices.last?.title == "Text from iphone")
        #expect(await r.system.notices.last?.text == "Milk, coffee")
        let item = try #require(await r.box.items().last)
        #expect(item.to == "computer" && item.from == "iphone" && item.seen == false && item.text == "Milk, coffee")
        let empty = await r.call("POST", "/api/text", json: #"{"text":"  "}"#)
        #expect(empty.status == 400)
        #expect(empty.bodyText == "Empty text")
    }

    @Test func unknownDeviceIsYourPhone() async throws {
        let r = try APIRig()
        _ = await r.call("POST", "/api/text", json: #"{"text":"hi"}"#, replacing: [("X-Forwarded-For", "100.99.0.1")])
        #expect(await r.box.items().last?.from == "your phone")
    }

    @Test func badJSON() async throws {
        let r = try APIRig()
        let bad = await r.call("POST", "/api/text", json: "{")
        #expect(bad.status == 400)
        #expect(bad.bodyText == "Bad request")
    }

    func upload(_ r: APIRig, _ query: String, _ data: Data, length: Int? = nil) async -> HTTPResponse {
        await r.call("POST", "/api/upload?\(query)", replacing: [("Content-Length", String(length ?? data.count))],
                     body: HTTPBody(data: data))
    }

    @Test func uploadToDownloads() async throws {
        let r = try APIRig()
        let data = Data(repeating: 1, count: 1024)
        let res = await upload(r, "name=Lasku%20%26%20kuitti.pdf&type=application/pdf", data)
        #expect(res.status == 200)
        #expect(res.json["name"] as? String == "Lasku & kuitti.pdf")
        #expect(try Data(contentsOf: r.system.downloads.appending(path: "Lasku & kuitti.pdf")) == data)
        let item = try #require(await r.box.items().last)
        #expect(item.kind == "file" && item.name == "Lasku & kuitti.pdf" && item.size == 1024 && item.type == "application/pdf")
        #expect(item.from == "iphone")
        let unnamed = await upload(r, "name=photo.heic", Data([1]))
        #expect(unnamed.status == 200)
        #expect(await r.box.items().last?.type == "image/heic")   // from the name when the query has no type
    }

    #if os(macOS)
    @Test func uploadsAreQuarantined() async throws {   // Final review: opened from the notification with no Gatekeeper check
        let r = try APIRig()
        _ = await upload(r, "name=run.command&type=application/octet-stream", Data("#!/bin/sh\n".utf8))
        let path = r.system.downloads.appending(path: "run.command").path
        #expect(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
    }
    #endif

    @Test func uploadLimits() async throws {
        let r = try APIRig()
        let big = await upload(r, "name=a.bin", Data(), length: Int((4 << 30) + 1))
        #expect(big.status == 413)
        #expect(big.bodyText == "Too big: 4.3 GB at most")
        r.system.set(free: 2 << 30)
        let full = await upload(r, "name=a.bin", Data([1, 2, 3]))
        #expect(full.status == 507)
        #expect(full.bodyText == "Not enough space on the computer")
    }

    @Test func brokenUpload() async throws {   // Review Focus 2
        let r = try APIRig()
        let sent = Mutex(false)
        let body = HTTPBody {
            if sent.withLock({ s in defer { s = true }; return s }) { throw URLError(.networkConnectionLost) }
            return Data(repeating: 9, count: 512)
        }
        let res = await r.call("POST", "/api/upload?name=movie.mov", replacing: [("Content-Length", "100000")], body: body)
        #expect(res.status == 400)
        #expect(res.bodyText == "Upload failed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.system.downloads.path).isEmpty)
        #expect(await r.box.items().isEmpty)
    }

    @Test func sameNameAtOnce() async throws {   // Review Focus 3
        let r = try APIRig()
        let gate = Mutex(0)
        // Both bodies hold until both uploads have started writing, so their .part files exist at the same time
        func slowBody(_ byte: UInt8) -> HTTPBody {
            let step = Mutex(0)
            return HTTPBody {
                let n = step.withLock { s in defer { s += 1 }; return s }
                if n == 0 { gate.withLock { $0 += 1 }; return Data(repeating: byte, count: 10) }
                while gate.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
                return n == 1 ? Data(repeating: byte, count: 10) : nil
            }
        }
        async let a = r.call("POST", "/api/upload?name=IMG_0001.JPG&type=image/jpeg", replacing: [("Content-Length", "20")], body: slowBody(1))
        async let b = r.call("POST", "/api/upload?name=IMG_0001.JPG&type=image/jpeg", replacing: [("Content-Length", "20")], body: slowBody(2))
        let names = [await a, await b].compactMap { $0.json["name"] as? String }.sorted()
        #expect(names == ["IMG_0001 (2).JPG", "IMG_0001.JPG"])
        for n in names {
            #expect(try Data(contentsOf: r.system.downloads.appending(path: n)).count == 20)
        }
    }

    @Test func clipImage() async throws {
        let r = try APIRig()
        _ = await upload(r, "name=shot.png&type=image/png&clip=1", Data([1, 2]))
        #expect(await r.system.clipboardImage?.1 == "image/png")
        #expect(await r.system.clipboardSensitive == true)
        #expect(await r.system.notices.last?.title == "Copied shot.png")
        #expect(await r.system.notices.last?.body == "From iphone · \(r.system.downloads.lastPathComponent)")
        let r2 = try APIRig()
        _ = await upload(r2, "name=a.pdf&type=application/pdf&clip=1", Data([1]))
        #expect(await r2.system.clipboardImage == nil)
    }

    @Test func filesGroupInOneNotice() async throws {
        let r = try APIRig()
        _ = await upload(r, "name=a.jpg&type=image/jpeg", Data([1]))
        r.clock.advance(5)
        _ = await upload(r, "name=b.jpg&type=image/jpeg", Data([1]))
        r.clock.advance(30)
        _ = await upload(r, "name=c.jpg&type=image/jpeg", Data([1]))
        let n = await r.system.notices
        #expect(n.count == 3)
        #expect(n[0].title == "Received a.jpg")
        #expect(n[1].id == n[0].id)
        #expect(n[1].title == "Received 2 files")
        #expect(n[1].files.count == 2)
        #expect(n[2].id != n[0].id)
        #expect(n[2].title == "Received c.jpg")
    }

    @Test func fileServing() async throws {
        let r = try APIRig()
        let folder = tempFolder()
        func left(_ name: String, _ type: String) async throws -> BoxItem {
            let src = folder.appending(path: name)
            try Data("x".utf8).write(to: src)
            return try await r.box.leaveFile(src, for: "")
        }
        let png = try await left("Kuva 1.png", "image/png")
        let res = await r.call("GET", "/api/file/\(png.id)")
        #expect(res.status == 200)
        #expect(res.header("Content-Type") == "image/png")
        #expect(res.header("Content-Disposition") == "inline; filename*=UTF-8''Kuva%201.png")
        #expect(res.header("Content-Security-Policy")?.hasPrefix("sandbox") == true)
        guard case .file(_, let n) = res.body else { Issue.record("not a file"); return }
        #expect(n == 1)
        let html = try await left("page.html", "text/html")
        #expect(await r.call("GET", "/api/file/\(html.id)").header("Content-Type") == "application/octet-stream")
        #expect(await r.call("GET", "/api/file/\(png.id)?download=1").header("Content-Disposition")?.hasPrefix("attachment") == true)
        let pdf = try await left("a.pdf", "application/pdf")
        #expect(await r.call("GET", "/api/file/\(pdf.id)").header("Content-Security-Policy") == nil)   // Safari's PDF viewer won't open sandboxed
        let gone = await r.call("GET", "/api/file/ffffffffffff")
        #expect(gone.status == 404)
        #expect(gone.bodyText == "Not in the box any more")
    }

    @Test func removeAndClear() async throws {
        let r = try APIRig()
        await r.box.append([BoxItem(id: "aaaaaaaaaaaa", to: "phone", kind: "text", time: r.clock.now, text: "a"),
                            BoxItem(id: "bbbbbbbbbbbb", to: "computer", kind: "text", time: r.clock.now, text: "b"),
                            BoxItem(id: "cccccccccccc", to: "computer", kind: "text", time: r.clock.now, text: "c")])
        #expect(await r.call("POST", "/api/remove?id=nope").status == 200)
        _ = await r.call("POST", "/api/remove?id=bbbbbbbbbbbb")
        #expect(await r.box.items().map(\.id) == ["aaaaaaaaaaaa", "cccccccccccc"])
        _ = await r.call("POST", "/api/clear?to=computer")
        #expect(await r.box.items().map(\.id) == ["aaaaaaaaaaaa"])
    }

    // MARK: Notifications

    @Test func subscribeOnlyDirect() async throws {
        let r = try APIRig()
        let keys = PushKeys.generate()
        let sub = #"{"endpoint":"https://push.nightdrive.sh/push/a","keys":{"p256dh":"\#(keys.p256dh)","auth":"\#(keys.authString)"}"#
        #expect(await r.call("POST", "/api/subscribe", json: sub + #","direct":true}"#).status == 200)
        let stored = await r.pusher.subscriptions()
        #expect(stored.count == 1)
        #expect(stored.first?.device == "iphone")
        #expect(stored.first?.direct == true)
        let page = await r.call("POST", "/api/subscribe", json: sub + "}")
        #expect(page.status == 400)
        #expect(page.bodyText == "Ferry on this Mac notifies only the Ferry app")
        let http = await r.call("POST", "/api/subscribe", json: #"{"endpoint":"http://x/","keys":{"p256dh":"a","auth":"b"},"direct":true}"#)
        #expect(http.status == 400)
        #expect(http.bodyText == "Not a push subscription")
        _ = await r.call("POST", "/api/unsubscribe", json: #"{"endpoint":"https://push.nightdrive.sh/push/a"}"#)
        #expect(await r.pusher.subscriptions().isEmpty)
    }

    @Test func relayChecks() async throws {
        let r = try APIRig()
        #expect(await r.call("POST", "/api/relay", json: #"{"via":"https://nightdrive.tail1234.ts.net/ferry/"}"#).status == 200)
        #expect(await r.pusher.relays() == ["https://nightdrive.tail1234.ts.net/ferry/"])
        let stranger = await r.call("POST", "/api/relay", json: #"{"via":"https://stranger.tail1234.ts.net/ferry/"}"#)
        #expect(stranger.status == 400)
        #expect(stranger.bodyText == "Not a Ferry page of yours")
        #expect(await r.call("POST", "/api/relay", json: #"{"via":"https://macbook.tail1234.ts.net/ferry/"}"#).status == 400)
        #expect(await r.call("POST", "/api/relay", json: #"{"via":"https://nightdrive.tail1234.ts.net/other/"}"#).status == 400)
        let push = await r.call("POST", "/api/relay-push",
                                json: #"{"title":"Nightdrive","body":"hi","machine":"https://nightdrive.tail1234.ts.net/ferry/"}"#)
        #expect(push.status == 200)
        let bad = await r.call("POST", "/api/relay-push", json: #"{"title":"x","body":"y","machine":"https://stranger.tail1234.ts.net/ferry/"}"#)
        #expect(bad.status == 400)
    }

    // MARK: The rest

    @Test func noPage() async throws {
        let r = try APIRig()
        let page = await r.call("GET", "/", replacing: [("X-Ferry", nil)])
        #expect(page.status == 404)
        #expect(page.bodyText == "Ferry on this Mac has no web page. Use the Ferry app on your phone.")
        #expect(await r.call("POST", "/api/test-push").status == 404)
        #expect(await r.call("GET", "/api/nothing").bodyText == "Not found")
    }
}
