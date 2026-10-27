import Foundation
import Testing
@testable import FerryServer

@Suite struct DevicesTests {
    let nd = KnownComputer(id: "nightdrive", name: "Nightdrive", url: "https://nightdrive.tail1234.ts.net/ferry/", idle: 0, seen: 1)
    let studio = KnownComputer(id: "studio", name: "Studio", url: "https://studio.tail1234.ts.net/ferry/", idle: 300, seen: 1)

    @Test func devicesFromTheFixture() throws {
        let view = TailnetView(statusJSON: try Fixture.data("tailscale-status"))
        let d = Devices.list(view: view, known: [studio, nd], phones: ["iphone"])
        #expect(d.map(\.id) == ["nightdrive", "studio", "iphone"])   // computers by name, then phones
        #expect(d[0] == Device(id: "nightdrive", name: "Nightdrive", kind: .computer, online: true, inUse: true))
        #expect(d[1] == Device(id: "studio", name: "Studio", kind: .computer, online: false, inUse: false))
        #expect(d[2] == Device(id: "iphone", name: "iphone", kind: .phone, online: true, inUse: false))
        // A known machine Tailscale no longer lists as the owner's is left out
        let gone = KnownComputer(id: "stranger", name: "Stranger", url: "https://stranger.tail1234.ts.net/ferry/", idle: 0, seen: 1)
        #expect(!Devices.list(view: view, known: [gone], phones: ["stranger"]).contains { $0.id == "stranger" })
    }

    @Test func tabletsAreTablets() throws {
        var view = TailnetView(statusJSON: try Fixture.data("tailscale-status"))
        view.peers.append(.init(id: "jaris-ipad", dnsName: "jaris-ipad.tail1234.ts.net", os: "iOS", online: false, hostName: "localhost"))
        #expect(Devices.list(view: view, known: [], phones: ["jaris-ipad"]).first { $0.id == "jaris-ipad" }?.kind == .tablet)
    }

    /// docs/protocol.md › Forgetting a device: a phone on the tailnet is listed only once it has used Ferry here
    @Test func phonesOnlyOnceTheyUsedFerry() throws {
        let view = TailnetView(statusJSON: try Fixture.data("tailscale-status"))
        #expect(Devices.list(view: view, known: [nd], phones: []).map(\.id) == ["nightdrive"])
        // A computer in the list of devices that asked is still listed only when it answers as Ferry
        #expect(Devices.list(view: view, known: [], phones: ["iphone", "nightdrive"]).map(\.id) == ["iphone"])
    }

    @Test func targetRule() {
        let phone = Device(id: "iphone", name: "iphone", kind: .phone, online: false, inUse: false)
        let pixel = Device(id: "pixel", name: "pixel", kind: .phone, online: true, inUse: false)
        let ndD = Device(id: "nightdrive", name: "Nightdrive", kind: .computer, online: true, inUse: true)
        let studioD = Device(id: "studio", name: "Studio", kind: .computer, online: false, inUse: false)
        let all = [ndD, studioD, phone, pixel]
        #expect(Devices.target(all, picked: "studio") == studioD)
        #expect(Devices.target(all, picked: nil) == pixel)        // a phone, an online one first
        #expect(Devices.target(all, picked: "gone") == pixel)     // a pick no longer there is no pick
        #expect(Devices.target([ndD, studioD], picked: nil) == ndD)
        #expect(Devices.target([], picked: nil) == nil)
    }
}

/// The phones that have used Ferry here (phones.json)
@Suite struct PhonesTests {
    @Test func recordsANewNameOnce() async throws {
        let state = tempFolder()
        let phones = Phones(state: state)
        #expect(await phones.names.isEmpty)
        await phones.used(by: "iphone")
        await phones.used(by: "iphone")
        await phones.used(by: "your phone")   // what an asker Tailscale can't name is called
        await phones.used(by: "")
        #expect(await phones.names == ["iphone"])
        #expect(await Phones(state: state).names == ["iphone"])   // kept across launches
    }

    /// A Ferry from before the list: the phones subscribed there have used it, so an update doesn't empty the list
    @Test func seededFromTheSubscriptions() async throws {
        let state = tempFolder()
        let keys = Subscription.Keys(p256dh: "k", auth: "a")
        StateFile.save([Subscription(endpoint: "https://p/1", keys: keys, device: "iphone", time: 0, direct: true),
                        Subscription(endpoint: "https://p/2", keys: keys, device: "your phone", time: 0, direct: nil)],
                       state.appending(path: "push.json"))
        #expect(await Phones(state: state).names == ["iphone"])
        // Seeded once: the list is its own from then on
        StateFile.save([Subscription(endpoint: "https://p/3", keys: keys, device: "ipad", time: 0, direct: true)],
                       state.appending(path: "push.json"))
        #expect(await Phones(state: state).names == ["iphone"])
    }
}

@Suite struct PublisherTests {
    @Test func servingParse() {
        let on = Data(#"{"TCP":{"443":{"HTTPS":true}},"Web":{"macbook.tail1234.ts.net:443":{"Handlers":{"/ferry":{"Proxy":"http://127.0.0.1:47270"}}}}}"#.utf8)
        #expect(Publisher.serving(statusJSON: on, port: 47270, httpsPort: 443, mount: "/ferry"))
        #expect(!Publisher.serving(statusJSON: on, port: 47271, httpsPort: 443, mount: "/ferry"))
        #expect(!Publisher.serving(statusJSON: on, port: 47270, httpsPort: 8443, mount: "/ferry"))
        #expect(!Publisher.serving(statusJSON: Data("{}".utf8), port: 47270, httpsPort: 443, mount: "/ferry"))
        #expect(!Publisher.serving(statusJSON: Data("No serve config".utf8), port: 47270, httpsPort: 443, mount: "/ferry"))
    }

    @Test func problemLink() {
        let out = "Serve is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/serve?node=abc\n\n"
        #expect(Publisher.problem(out) == .problem(message: "https://login.tailscale.com/f/serve?node=abc",
                                                   link: URL(string: "https://login.tailscale.com/f/serve?node=abc")))
        #expect(Publisher.problem("error: something broke") == .problem(message: "error: something broke", link: nil))
        #expect(Publisher.problem("") == .problem(message: "tailscale serve failed", link: nil))
    }
}
