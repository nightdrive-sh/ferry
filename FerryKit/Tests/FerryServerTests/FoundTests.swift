import Foundation
import Synchronization
import Testing
@testable import FerryServer

@Suite struct FoundTests {
    /// A probe that answers as Ferry for the hosts in `ferry`, and counts who was asked
    final class Probe: Sendable {
        let ferry: Set<String>
        let asked = Mutex<[String]>([])
        init(_ ferry: Set<String>) { self.ferry = ferry }
        var function: @Sendable (String) async -> Probed? {
            { host in
                self.asked.withLock { $0.append(host) }
                return self.ferry.contains(host) ? Probed(url: "https://\(host)/ferry/", name: host.capitalized, id: host, idle: 0) : nil
            }
        }
        func take() -> [String] { asked.withLock { defer { $0 = [] }; return $0.sorted() } }
    }

    @Test func asksOnlyWhenDue() async {
        let probe = Probe(["a"])
        let clock = TestClock()
        let found = Found(config: ServerConfig(state: tempFolder()), probe: probe.function, clock: clock.function)
        #expect(await found.get(online: ["a", "b"]).map(\.id) == ["a"])
        #expect(probe.take() == ["a", "b"])
        clock.advance(5)
        #expect(await found.get(online: ["a", "b"]).map(\.id) == ["a"])
        #expect(probe.take() == [])
        #expect(await found.asked == [])
        clock.advance(6)   // 11 s: b didn't answer as Ferry, so it is asked again after 10 s
        _ = await found.get(online: ["a", "b"])
        #expect(probe.take() == ["b"])
        clock.advance(50)  // 61 s: a is asked again after a minute
        _ = await found.get(online: ["a", "b"])
        #expect(probe.take().contains("a"))
    }

    @Test func nothingDueAnswersAtOnce() async {
        let probe = Probe(["a"])
        let found = Found(config: ServerConfig(state: tempFolder()), probe: probe.function, clock: TestClock().function)
        _ = await found.get(online: ["a"])
        let start = ContinuousClock.now
        #expect(await found.get(online: ["a"]).count == 1)   // cached: api/machines mustn't wait for nothing
        #expect(await found.get(online: []).isEmpty)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func offlineLeavesAtOnce() async {
        let probe = Probe(["a"])
        let found = Found(config: ServerConfig(state: tempFolder()), probe: probe.function, clock: TestClock().function)
        #expect(await found.get(online: ["a"]).count == 1)
        _ = probe.take()
        #expect(await found.get(online: []).isEmpty)
        #expect(probe.take() == [])   // a sleeping machine is never asked
    }

    @Test func sortedByName() async {
        let probe = Probe(["zeta", "alpha", "Mid"])
        let found = Found(config: ServerConfig(state: tempFolder()), probe: probe.function, clock: TestClock().function)
        #expect(await found.get(online: ["zeta", "Mid", "alpha"]).map(\.id) == ["alpha", "Mid", "zeta"])
    }

    @Test func mergeKeepsSleepers() {
        let studio = KnownComputer(id: "studio", name: "Studio", url: "https://studio.tail1234.ts.net/ferry/", idle: nil, seen: 1)
        let nd = KnownComputer(id: "nightdrive", name: "Nightdrive", url: "https://nightdrive.tail1234.ts.net/ferry/", idle: 0, seen: 1)
        let found = [Probed(url: nd.url, name: "Nightdrive", id: "nightdrive", idle: 30)]
        let merged = Found.merge(known: [studio, nd], found: found, ids: ["studio", "nightdrive"], now: 5)
        #expect(merged.first { $0.id == "studio" }?.seen == 1)
        #expect(merged.first { $0.id == "nightdrive" }?.seen == 5)
        #expect(merged.first { $0.id == "nightdrive" }?.idle == 30)
        #expect(merged.count == 2)
        #expect(Found.merge(known: [studio, nd], found: found, ids: ["nightdrive"], now: 5).map(\.id) == ["nightdrive"])
    }

    @Test func probeAsksPing() async throws {
        let out = FakeOutbound()
        await out.set(status: 200, for: "nightdrive.tail1234.ts.net")
        await out.set(answer: Data(#"{"computer":"Nightdrive","idle":12}"#.utf8), for: "nightdrive.tail1234.ts.net")
        let config = ServerConfig(state: tempFolder())
        let p = await Found.probe(host: "nightdrive.tail1234.ts.net", config: config, outbound: out)
        #expect(p == Probed(url: "https://nightdrive.tail1234.ts.net/ferry/", name: "Nightdrive", id: "nightdrive", idle: 12))
        let r = try #require(await out.sent.first)
        #expect(r.request.url?.absoluteString == "https://nightdrive.tail1234.ts.net/ferry/api/ping")
        #expect(r.request.value(forHTTPHeaderField: "X-Ferry") == "1")
        #expect(r.request.timeoutInterval == 4)
        await out.set(status: 404, for: "studio.tail1234.ts.net")
        #expect(await Found.probe(host: "studio.tail1234.ts.net", config: config, outbound: out) == nil)
    }
}

@Suite struct ProbeTests {
    @Test func thePingCarriesTheForgottenList() async {
        let outbound = FakeOutbound()
        await outbound.set(status: 200, for: "studio.tail1234.ts.net")
        await outbound.set(answer: Data(#"{"computer":"Studio","idle":5,"forgotten":[{"device":"iphone","time":1,"forgotten":true},"x"]}"#.utf8),
                           for: "studio.tail1234.ts.net")
        let p = await Found.probe(host: "studio.tail1234.ts.net", config: ServerConfig(state: tempFolder()), outbound: outbound)
        #expect(p?.name == "Studio" && p?.idle == 5 && p?.id == "studio")
        #expect(p?.forgotten == [Forgetting(device: "iphone", time: 1, forgotten: true)])
    }

    @Test func anOlderFerrysPing() async {   // no list: nothing forgotten there
        let outbound = FakeOutbound()
        await outbound.set(status: 200, for: "old.tail1234.ts.net")
        await outbound.set(answer: Data(#"{"computer":"Old"}"#.utf8), for: "old.tail1234.ts.net")
        let p = await Found.probe(host: "old.tail1234.ts.net", config: ServerConfig(state: tempFolder()), outbound: outbound)
        #expect(p?.forgotten == [])
    }
}
