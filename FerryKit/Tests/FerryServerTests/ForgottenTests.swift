import Foundation
import Testing
@testable import FerryServer

/// docs/protocol.md › Forgetting a device: the list, how it merges, and what a decision here does.
@Suite struct ForgottenTests {
    func entry(_ device: String, _ time: Double, _ forgotten: Bool = true) -> Forgetting {
        Forgetting(device: device, time: time, forgotten: forgotten)
    }

    @Test func theLaterDecisionWins() {
        let mine = [entry("studio", 10), entry("iphone", 30, false)]
        let theirs = [entry("studio", 20, false), entry("iphone", 20)]
        #expect(Forgotten.merge(mine, theirs) == [entry("iphone", 30, false), entry("studio", 20, false)])
    }

    @Test func forgettingWinsATie() {
        #expect(Forgotten.merge([entry("studio", 5, false)], [entry("studio", 5)]) == [entry("studio", 5)])
        #expect(Forgotten.merge([entry("studio", 5)], [entry("studio", 5, false)]) == [entry("studio", 5)])
    }

    @Test func newDevicesAreTakenIn() {
        #expect(Forgotten.merge([], [entry("ipad", 1)]) == [entry("ipad", 1)])
    }

    /// Another computer's answer, as bin/ferry's merge_forgotten() takes it: what isn't an entry is left out
    @Test func entriesFromAnotherComputer() throws {
        let json = #"""
        [{"device": "ok", "time": 1, "forgotten": true}, "x", null,
         {"device": "no time", "time": 1, "forgotten": true}, {"device": "studio", "time": "1", "forgotten": true},
         {"device": "studio", "time": 1}, {"device": "studio", "time": 1, "forgotten": 1},
         {"device": "\#(String(repeating: "a", count: 64))", "time": 1, "forgotten": true},
         {"device": "x", "time": true, "forgotten": true}, {"device": "ok2", "time": 2.5, "forgotten": false, "name": "x"}]
        """#
        let parsed = Forgotten.entries(from: try JSONSerialization.jsonObject(with: Data(json.utf8)))
        #expect(parsed == [entry("ok", 1), entry("ok2", 2.5, false)])
        #expect(Forgotten.entries(from: ["not": "a list"]).isEmpty)
        #expect(Forgotten.entries(from: nil).isEmpty)
    }

    @Test func deviceNames() {
        for good in ["iphone", "nightdrive-pc", String(repeating: "a", count: 63), "MacBook-Pro-2"] {
            #expect(Forgotten.isDeviceName(good), "\(good)")
        }
        for bad in ["", String(repeating: "a", count: 64), "mac.tail0.ts.net", "../x", "x y", "äö"] {
            #expect(!Forgotten.isDeviceName(bad), "\(bad)")
        }
    }

    @Test func decideKeepsItAndATombstone() async {
        let state = tempFolder()
        let clock = TestClock(100)
        let f = Forgotten(state: state, clock: clock.function)
        #expect(await f.ids.isEmpty)
        await f.decide("studio", forget: true)
        #expect(await f.ids == ["studio"])
        clock.advance(100)
        await f.decide("studio", forget: false)
        #expect(await f.ids.isEmpty)
        #expect(await f.all == [entry("studio", 200, false)])
        // Kept across launches
        #expect(await Forgotten(state: state, clock: clock.function).all == [entry("studio", 200, false)])
    }

    /// Another computer's clock may be ahead of this one's: a decision made here still wins here
    @Test func aDecisionHereBeatsWhatIsKnownHere() async throws {
        let f = Forgotten(state: tempFolder(), clock: TestClock(100).function)
        #expect(await f.learn([entry("studio", 5000)]))
        await f.decide("studio", forget: false)
        #expect(await f.ids.isEmpty)
        #expect(try #require(await f.all.first).time > 5000)
    }

    @Test func learnSaysWhetherAnythingChanged() async {
        let state = tempFolder()
        let f = Forgotten(state: state, clock: TestClock().function)
        #expect(await f.learn([entry("iphone", 50), entry("studio", 50)]))
        #expect(await f.ids == ["iphone", "studio"])
        #expect(!(await f.learn([entry("iphone", 10, false)])))   // older: nothing new
        #expect(!(await f.learn([entry("studio", 50)])))
        #expect(await Forgotten(state: state, clock: TestClock().function).ids == ["iphone", "studio"])
    }

    /// bin/ferry writes it this way, so the Mac's file and Linux's read the same
    @Test func theWireForm() throws {
        let data = try JSONEncoder().encode([entry("studio", 1.5)])
        let back = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(back?.first?["device"] as? String == "studio")
        #expect(back?.first?["time"] as? Double == 1.5)
        #expect(back?.first?["forgotten"] as? Bool == true)
    }
}
