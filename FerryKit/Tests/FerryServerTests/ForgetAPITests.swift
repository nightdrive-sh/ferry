import FerryKit
import Foundation
import Testing
@testable import FerryServer

/// api/forget, api/unforget and what they change in the other calls (docs/protocol.md › Forgetting a device), and one
/// direct subscription per device.
@Suite struct ForgetAPITests {
    func subscribe(_ r: APIRig, _ endpoint: String) async -> Int {
        let keys = PushKeys.generate()
        return await r.call("POST", "/api/subscribe", json: #"{"endpoint":"\#(endpoint)","keys":{"p256dh":"\#(keys.p256dh)","auth":"\#(keys.authString)"},"direct":true}"#).status
    }

    @Test func forgetAndUnforget() async throws {
        let r = try APIRig()
        #expect(await r.call("POST", "/api/forget", json: "{}").status == 400)
        #expect(await r.call("POST", "/api/forget", json: #"{"device":"studio.tail1234.ts.net"}"#).status == 400)
        #expect(await r.call("POST", "/api/forget", json: #"{"device":5}"#).status == 400)
        // Tailscale's names are lowercase, and a name is a name however it is written
        #expect(await r.call("POST", "/api/forget", json: #"{"device":"Studio"}"#).status == 200)
        #expect(await r.forgotten.ids == ["studio"])
        r.clock.advance(1)
        let ok = await r.call("POST", "/api/forget", json: #"{"device":"studio"}"#)
        #expect(ok.status == 200)
        #expect(ok.json["ok"] as? Bool == true)
        #expect(await r.forgotten.ids == ["studio"])
        let ping = await r.call("GET", "/api/ping").json["forgotten"] as? [[String: Any]]
        #expect(ping?.first?["device"] as? String == "studio")
        #expect(ping?.first?["forgotten"] as? Bool == true)
        #expect(ping?.first?["time"] as? Double == r.clock.now)
        let machines = await r.call("GET", "/api/machines").json["forgotten"] as? [[String: Any]]
        #expect(machines?.count == 1)
        r.clock.advance(1)
        #expect(await r.call("POST", "/api/unforget", json: #"{"device":"studio"}"#).status == 200)
        #expect(await r.forgotten.ids.isEmpty)
        #expect(await r.forgotten.all == [Forgetting(device: "studio", time: r.clock.now, forgotten: false)])
    }

    @Test func forgettingAPhoneDropsItsSubscriptions() async throws {
        let r = try APIRig()   // asking as the iPhone
        #expect(await subscribe(r, "https://push.nightdrive.sh/push/a") == 200)
        await r.pusher.subscribe(Subscription(endpoint: "https://push.nightdrive.sh/push/ipad", keys: .init(p256dh: "k", auth: "a"),
                                              device: "ipad", time: 0, direct: true))
        _ = await r.call("POST", "/api/forget", json: #"{"device":"iphone"}"#)
        #expect(await r.pusher.subscriptions().map(\.device) == ["ipad"])
        // Answered as ever, but not kept
        #expect(await subscribe(r, "https://push.nightdrive.sh/push/b") == 200)
        #expect(await r.pusher.subscriptions().map(\.device) == ["ipad"])
        // Brought back, it subscribes again
        r.clock.advance(1)
        _ = await r.call("POST", "/api/unforget", json: #"{"device":"iphone"}"#)
        #expect(await subscribe(r, "https://push.nightdrive.sh/push/c") == 200)
        #expect(await r.pusher.subscriptions().map(\.device) == ["ipad", "iphone"])
    }

    /// 1644: an app installed again subscribes with a new address; the old one must not go on getting every notification
    @Test func aNewDirectSubscriptionReplacesTheDevicesOldOne() async throws {
        let r = try APIRig()
        _ = await subscribe(r, "https://push.nightdrive.sh/push/old")
        _ = await subscribe(r, "https://push.nightdrive.sh/push/new")
        #expect(await r.pusher.subscriptions().map(\.endpoint) == ["https://push.nightdrive.sh/push/new"])
    }

    @Test func anUnnamedDeviceReplacesNothing() async {
        let p = Pusher(state: tempFolder(), key: try! VAPIDKey.load(orCreateIn: tempFolder()), config: ServerConfig(state: tempFolder()),
                       outbound: FakeOutbound())
        let keys = Subscription.Keys(p256dh: "k", auth: "a")
        await p.subscribe(Subscription(endpoint: "https://p/1", keys: keys, device: "your phone", time: 0, direct: true))
        await p.subscribe(Subscription(endpoint: "https://p/2", keys: keys, device: "your phone", time: 0, direct: true))
        await p.subscribe(Subscription(endpoint: "https://p/3", keys: keys, device: "iphone", time: 0, direct: true))
        await p.subscribe(Subscription(endpoint: "https://p/4", keys: keys, device: "ipad", time: 0, direct: true))
        #expect(await p.subscriptions().map(\.endpoint) == ["https://p/1", "https://p/2", "https://p/3", "https://p/4"])
        await p.drop(devices: ["iphone", "nobody"])
        #expect(await p.subscriptions().map(\.endpoint) == ["https://p/1", "https://p/2", "https://p/4"])
    }
}
