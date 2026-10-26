import FerryKit
import Foundation
import Testing
@testable import FerryServer

@Suite struct PusherTests {
    let own = "https://macbook.tail1234.ts.net/ferry/"

    func sub(_ device: String, direct: Bool, endpoint: String? = nil, keys: PushKeys = .generate()) -> Subscription {
        Subscription(endpoint: endpoint ?? "https://push.example.com/\(device)-\(direct)",
                     keys: .init(p256dh: keys.p256dh, auth: keys.authString), device: device, time: 0,
                     direct: direct ? true : nil)
    }

    func pusher(_ outbound: FakeOutbound, state: URL = tempFolder()) throws -> Pusher {
        Pusher(state: state, key: try VAPIDKey.load(orCreateIn: state), config: ServerConfig(state: state), outbound: outbound)
    }

    @Test func recipientsRules() {
        let subs = [sub("iphone", direct: true), sub("iphone", direct: false), sub("ipad", direct: false),
                    sub("your phone", direct: true)]
        func names(_ s: [Subscription]) -> [String] { s.map { "\($0.device)\($0.direct == true ? "+" : "")" } }
        // The app's direct subscription quiets the same phone's PWA; "your phone" could be anyone's, so it replaces nothing
        #expect(names(Pusher.recipients(subs, relayed: false, device: "")) == ["iphone+", "ipad", "your phone+"])
        // Passed on from another computer: the app hears from that computer itself
        #expect(names(Pusher.recipients(subs, relayed: true, device: "")) == ["ipad"])
        #expect(names(Pusher.recipients(subs, relayed: false, device: "iphone")) == ["iphone+"])
    }

    @Test func pushesToTheRelay() async throws {
        let out = FakeOutbound()
        let p = try pusher(out)
        let keys = PushKeys.generate()
        await p.subscribe(sub("iphone", direct: true, endpoint: "https://push.nightdrive.sh/push/abc", keys: keys))
        let item = BoxItem(id: "a1b2c3d4e5f6", to: "phone", kind: "text", time: 0, text: "801566", for: "iphone")
        await p.push(title: "MacBook", body: "801566", item: item, device: "iphone", own: own)
        let sent = await out.sent
        #expect(sent.count == 1)
        let r = try #require(sent.first)
        #expect(r.request.url?.absoluteString == "https://push.nightdrive.sh/push/abc")
        #expect(r.request.httpMethod == "POST")
        #expect(r.request.value(forHTTPHeaderField: "Urgency") == "high")
        #expect(r.request.value(forHTTPHeaderField: "TTL") == "604800")
        #expect(r.request.value(forHTTPHeaderField: "Content-Encoding") == "aes128gcm")
        #expect(r.request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("vapid t=") == true)
        let json = try JSONSerialization.jsonObject(with: PushCrypto.decrypt(r.body, with: keys)) as? [String: Any]
        #expect(json?["title"] as? String == "MacBook")
        #expect(json?["text"] as? String == "801566")
        #expect(json?["id"] as? String == "a1b2c3d4e5f6")
    }

    @Test func goneSubscriptionDropped() async throws {
        let state = tempFolder()
        let out = FakeOutbound()
        await out.set(status: 410, for: "push.nightdrive.sh")
        let p = try pusher(out, state: state)
        await p.subscribe(sub("iphone", direct: true, endpoint: "https://push.nightdrive.sh/push/abc"))
        let attrs = try FileManager.default.attributesOfItem(atPath: state.appending(path: "push.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await p.push(title: "MacBook", body: "x", own: own)
        #expect(await p.subscriptions().isEmpty)
        let again = try pusher(FakeOutbound(), state: state)
        #expect(await again.subscriptions().isEmpty)   // saved
    }

    @Test func subscribingAgainReplaces() async throws {
        let p = try pusher(FakeOutbound())
        await p.subscribe(sub("iphone", direct: true, endpoint: "https://push.nightdrive.sh/push/abc"))
        await p.subscribe(sub("iphone", direct: true, endpoint: "https://push.nightdrive.sh/push/abc"))
        #expect(await p.subscriptions().count == 1)
        await p.unsubscribe(endpoint: "https://push.nightdrive.sh/push/abc")
        #expect(await p.subscriptions().isEmpty)
    }

    @Test func relaysPassItOn() async throws {
        let out = FakeOutbound()
        let p = try pusher(out)
        await p.addRelay("https://nightdrive.tail1234.ts.net/ferry/")
        await p.addRelay(own)
        await p.addRelay("https://nightdrive.tail1234.ts.net/ferry/")
        #expect(await p.relays().count == 2)
        await p.push(title: "MacBook", body: "hi", device: "pixel", own: own)
        let sent = await out.sent
        #expect(sent.count == 1)
        let r = try #require(sent.first)
        #expect(r.request.url?.absoluteString == "https://nightdrive.tail1234.ts.net/ferry/api/relay-push")
        #expect(r.request.value(forHTTPHeaderField: "X-Ferry") == "1")
        let body = try JSONSerialization.jsonObject(with: r.body) as? [String: String]
        #expect(body == ["title": "MacBook", "body": "hi", "machine": own, "device": "pixel"])
        // A code goes on as the placeholder: the page's notification shows the body as it is (docs/protocol.md ›
        // Codes and passwords)
        await p.push(title: "MacBook", body: "801566", item: BoxItem(id: "c", to: "phone", kind: "text", time: 0, text: "801566"),
                     own: own)
        let code = try JSONSerialization.jsonObject(with: try #require(await out.sent.last).body) as? [String: String]
        #expect(code?["body"] == "Code or password · open to see")
        // A notification another computer passed on goes no further
        await p.push(title: "Nightdrive", body: "hi", machine: "https://nightdrive.tail1234.ts.net/ferry/", own: own)
        #expect(await out.sent.count == 2)
    }
}
