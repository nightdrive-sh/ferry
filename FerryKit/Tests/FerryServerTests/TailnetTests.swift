import Foundation
import Testing
@testable import FerryServer

@Suite struct TailnetTests {
    @Test func readsTheView() throws {
        let v = TailnetView(statusJSON: try Fixture.data("tailscale-status"))
        #expect(v.running)
        #expect(v.owner == "jari@example.com")
        #expect(v.me == "macbook.tail1234.ts.net")
        #expect(v.onlineComputers == ["nightdrive.tail1234.ts.net"])   // not studio (off), iphone (iOS), stranger
        #expect(v.ids == ["nightdrive", "studio", "iphone"])
        #expect(v.hosts.contains("macbook.tail1234.ts.net") && v.hosts.contains("studio.tail1234.ts.net"))
        #expect(!v.hosts.contains("stranger.tail1234.ts.net"))
        #expect(v.names["100.64.0.4"] == "iphone")   // the DNS name, not HostName "localhost"
        #expect(v.names["100.64.0.1"] == "macbook")
        #expect(v.peers.first { $0.id == "iphone" }?.os == "iOS")
        #expect(v.peers.first { $0.id == "studio" }?.online == false)
        #expect(!v.peers.contains { $0.id == "stranger" })
    }

    @Test func gate() async {
        let t = Tailnet(cli: FakeTailscale(), clock: TestClock().function)
        #expect(await t.allowed(login: "jari@example.com"))
        #expect(await !t.allowed(login: "other@example.com"))
        #expect(await !t.allowed(login: ""))
        #expect(await t.forMe(host: "macbook.tail1234.ts.net:443"))
        #expect(await t.forMe(host: "macbook.tail1234.ts.net"))
        #expect(await !t.forMe(host: "127.0.0.1:47270"))
        #expect(await t.device(ip: "100.64.0.4") == "iphone")
        #expect(await t.device(ip: "100.64.9.9") == "")
        #expect(await t.baseURL() == URL(string: "https://macbook.tail1234.ts.net/ferry/"))
    }

    /// Another of the owner's machines is trusted only as Ferry: its origin on Ferry's port and its base URL at
    /// /ferry/, not another web app on another port of it (FER-08, as linux/tests/test_origins.py)
    @Test func aFerryPageOnAnotherOfTheOwnersMachines() async {
        let t = Tailnet(cli: FakeTailscale(), clock: TestClock().function)
        #expect(await t.sameOrigin("https://nightdrive.tail1234.ts.net"))
        #expect(await t.sameOrigin("https://macbook.tail1234.ts.net"))
        #expect(await t.sameOrigin("https://nightdrive.tail1234.ts.net:8443", httpsPort: 8443))
    }

    @Test func anotherPortUserOrSchemeIsAnotherApp() async {
        let t = Tailnet(cli: FakeTailscale(), clock: TestClock().function)
        for o in ["https://nightdrive.tail1234.ts.net:8443", "https://nightdrive.tail1234.ts.net:443",
                  "http://nightdrive.tail1234.ts.net", "https://me@nightdrive.tail1234.ts.net",
                  "https://nightdrive.tail1234.ts.net/", "https://NIGHTDRIVE.tail1234.ts.net",
                  "https://nightdrive.tail1234.ts.net:bad", "https://[nightdrive", "", "null",
                  "https://nightdrive%2Etail1234.ts.net"] {
            #expect(await !t.sameOrigin(o), "\(o)")
        }
        #expect(await !t.sameOrigin("https://nightdrive.tail1234.ts.net", httpsPort: 8443))
    }

    @Test func anotherUsersMachineIsntTheOwners() async {
        let t = Tailnet(cli: FakeTailscale(), clock: TestClock().function)
        #expect(await !t.sameOrigin("https://stranger.tail1234.ts.net"))
        #expect(await !t.sameBase("https://stranger.tail1234.ts.net/ferry/"))
    }

    @Test func aBaseURLIsFerrysOwn() async {
        let t = Tailnet(cli: FakeTailscale(), clock: TestClock().function)
        #expect(await t.sameBase("https://nightdrive.tail1234.ts.net/ferry/"))
        for u in ["https://nightdrive.tail1234.ts.net/ferry", "https://nightdrive.tail1234.ts.net/other/ferry/",
                  "https://nightdrive.tail1234.ts.net:8443/ferry/", "https://nightdrive.tail1234.ts.net/ferry/?x",
                  "https://nightdrive.tail1234.ts.net/ferry/#x", "https://nightdrive.tail1234.ts.net"] {
            #expect(await !t.sameBase(u), "\(u)")
        }
    }

    @Test func refreshesOnAMiss() async {
        let cli = FakeTailscale()
        let clock = TestClock()
        let t = Tailnet(cli: cli, clock: clock.function)
        _ = await t.allowed(login: "jari@example.com")
        #expect(await cli.statusCalls == 1)
        _ = await t.allowed(login: "jari@example.com")
        #expect(await cli.statusCalls == 1)   // cached
        _ = await t.allowed(login: "someone@example.com")
        #expect(await cli.statusCalls == 2)   // the owner may have just logged in
        clock.advance(61)
        _ = await t.forMe(host: "macbook.tail1234.ts.net")
        #expect(await cli.statusCalls == 3)   // a minute old
    }

    @Test func tailscaleOffDeniesAll() async {   // Review Focus 5
        let cli = FakeTailscale()
        await cli.set(status: nil)   // the command fails
        let t = Tailnet(cli: cli, clock: TestClock().function)
        #expect(await !t.allowed(login: "jari@example.com"))
        #expect(await !t.allowed(login: ""))
        #expect(await t.baseURL() == nil)
        await cli.set(status: Data(#"{"BackendState":"NeedsLogin","Self":{"DNSName":"","UserID":0}}"#.utf8))
        let t2 = Tailnet(cli: cli, clock: TestClock().function)
        #expect(await !t2.allowed(login: "jari@example.com"))
        #expect(await !t2.allowed(login: ""))
        #expect(await !t2.forMe(host: ""))
        #expect(await t2.baseURL() == nil)
    }
}
