import Foundation
import Testing
@testable import FerryServer

@Suite struct DevicesTests {
    let nd = KnownComputer(id: "nightdrive", name: "Nightdrive", url: "https://nightdrive.tail1234.ts.net/ferry/", idle: 0, seen: 1)
    let studio = KnownComputer(id: "studio", name: "Studio", url: "https://studio.tail1234.ts.net/ferry/", idle: 300, seen: 1)

    @Test func devicesFromTheFixture() throws {
        let view = TailnetView(statusJSON: try Fixture.data("tailscale-status"))
        let d = Devices.list(view: view, known: [studio, nd])
        #expect(d.map(\.id) == ["nightdrive", "studio", "iphone"])   // computers by name, then phones
        #expect(d[0] == Device(id: "nightdrive", name: "Nightdrive", kind: .computer, online: true, inUse: true))
        #expect(d[1] == Device(id: "studio", name: "Studio", kind: .computer, online: false, inUse: false))
        #expect(d[2] == Device(id: "iphone", name: "iphone", kind: .phone, online: true, inUse: false))
        // A known machine Tailscale no longer lists as the owner's is left out
        let gone = KnownComputer(id: "stranger", name: "Stranger", url: "https://stranger.tail1234.ts.net/ferry/", idle: 0, seen: 1)
        #expect(!Devices.list(view: view, known: [gone]).contains { $0.id == "stranger" })
    }

    @Test func tabletsAreTablets() throws {
        var view = TailnetView(statusJSON: try Fixture.data("tailscale-status"))
        view.peers.append(.init(id: "jaris-ipad", dnsName: "jaris-ipad.tail1234.ts.net", os: "iOS", online: false, hostName: "localhost"))
        #expect(Devices.list(view: view, known: []).first { $0.id == "jaris-ipad" }?.kind == .tablet)
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
