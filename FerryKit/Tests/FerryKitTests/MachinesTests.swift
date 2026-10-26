import Foundation
import Testing
@testable import FerryKit

let mac = URL(string: "https://macbook.tail1.ts.net/ferry/")!
let nd = URL(string: "https://nightdrive.tail1.ts.net/ferry/")!
let mini = URL(string: "https://mini.tail1.ts.net/ferry/")!
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Nightdrive set up first, then MacBook and Mini found.
func three() -> MachineList {
    var l = MachineList()
    l.add(nd, name: "Nightdrive", at: t0, asSetup: true)
    l.merge([MachineInfo(url: mac, name: "MacBook"), MachineInfo(url: mini, name: "Mini")], at: t0)
    return l
}

@Suite struct MachinesTests {
    @Test func trailingSlashIsOneMachine() {   // Review Focus 2
        var l = MachineList()
        l.add(URL(string: "https://NightDrive.tail1.ts.net/ferry")!, name: "Nightdrive", at: t0, asSetup: true)
        l.merge([MachineInfo(url: nd, name: "Nightdrive", isSelf: true)], at: t0)
        #expect(l.machines.count == 1)
        #expect(l.machines[0].url == nd)
    }

    @Test func normalized() {
        #expect(MachineList.normalized(URL(string: "https://NightDrive.tail1.ts.net/ferry")!) == nd)
        #expect(MachineList.normalized(URL(string: "https://nightdrive.tail1.ts.net/ferry//")!) == nd)
        #expect(MachineList.normalized(URL(string: "http://127.0.0.1:47271/ferry")!) == URL(string: "http://127.0.0.1:47271/ferry/")!)
    }

    @Test func mergeUpdatesNameAndSeen() {
        var l = three()
        l.merge([MachineInfo(url: mac, name: "MacBook Pro")], at: t0 + 60)
        let m = l.machines.first { $0.url == mac }
        #expect(m?.name == "MacBook Pro")
        #expect(m?.lastSeen == t0 + 60)
        #expect(l.machines.first { $0.url == nd }?.lastSeen == t0)   // not in the answer: unchanged
    }

    @Test func mergeAddsNew() {
        var l = three()
        l.merge([MachineInfo(url: URL(string: "https://office.tail1.ts.net/ferry/")!, name: "Office PC")], at: t0)
        #expect(l.machines.count == 4)
        #expect(l.machines.filter(\.isSetup).count == 1)
    }

    @Test func forgetStaleAfterSevenDays() {
        var l = three()
        l.markSeen(nd, at: t0 + 86400)                         // seen 6 days before `now`
        l.forgetStale(now: t0 + 7 * 86400 + 1)
        #expect(l.machines.map(\.url) == [nd])                 // MacBook and Mini: 7 days and 1 s
    }

    @Test func forgetSetupPromotesAnother() {
        var l = three()
        l.markSeen(mini, at: t0 + 100)
        l.forget(nd)
        #expect(l.machines.count == 2)
        #expect(l.setup?.url == mini)                          // the one seen most recently
    }

    @Test func makeSetup() {
        var l = three()
        l.makeSetup(mac)
        #expect(l.setup?.url == mac)
        #expect(l.machines.filter(\.isSetup).count == 1)
    }

    @Test func orderByIdle() {
        let s: [URL: MachineStatus] = [mac: .init(reachable: true, idle: 0), nd: .init(reachable: true, idle: 1200),
                                       mini: .init(reachable: true, idle: nil)]
        #expect(TargetRule.order(three().machines, status: s).map(\.name) == ["MacBook", "Nightdrive", "Mini"])
    }

    @Test func tieGoesToSetup() {
        let s: [URL: MachineStatus] = [mac: .init(reachable: true, idle: nil), nd: .init(reachable: true, idle: nil)]
        #expect(TargetRule.order(three().machines, status: s).first?.url == nd)
    }

    @Test func unreachableSkipped() {
        let s: [URL: MachineStatus] = [mac: .init(reachable: false, idle: 0), nd: .init(reachable: true, idle: 1200)]
        #expect(TargetRule.target(three().machines, status: s, manual: nil) == nd)
    }

    @Test func notAskedYetCountsAsReachable() {   // right after launch, before the first poll
        #expect(TargetRule.target(three().machines, status: [:], manual: nil) == nd)
    }

    @Test func manualWins() {
        let s: [URL: MachineStatus] = [mac: .init(reachable: true, idle: 0), mini: .init(reachable: true, idle: 9999)]
        #expect(TargetRule.target(three().machines, status: s, manual: mini) == mini)
    }

    @Test func manualUnreachableFallsBack() {   // Review Focus 5
        let s: [URL: MachineStatus] = [mac: .init(reachable: true, idle: 0), mini: .init(reachable: false, idle: nil)]
        #expect(TargetRule.target(three().machines, status: s, manual: mini) == mac)
    }

    @Test func manualForgottenFallsBack() {
        let gone = URL(string: "https://gone.tail1.ts.net/ferry/")!
        #expect(TargetRule.target(three().machines, status: [mac: .init(reachable: true, idle: 0)], manual: gone) == mac)
    }

    @Test func allUnreachableFallsToSetup() {
        let s: [URL: MachineStatus] = [mac: .init(reachable: false), nd: .init(reachable: false), mini: .init(reachable: false)]
        #expect(TargetRule.target(three().machines, status: s, manual: nil) == nd)
    }

    @Test func noMachinesNoTarget() {
        #expect(TargetRule.target([], status: [:], manual: nil) == nil)
    }

    @Test func usedLabels() {
        #expect(TargetRule.usedLabel(.init(reachable: true, idle: 0)) == "in use")
        #expect(TargetRule.usedLabel(.init(reachable: true, idle: 1200)) == "used 20 min ago")
        #expect(TargetRule.usedLabel(.init(reachable: true, idle: 3 * 86400)) == "used 3 d ago")
        #expect(TargetRule.usedLabel(.init(reachable: false, idle: 0)) == "can't reach")
        #expect(TargetRule.usedLabel(.init(reachable: true, idle: nil)) == "")
        #expect(TargetRule.usedLabel(nil) == "")
    }

    @Test func storeRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = MachineStore(defaults: defaults)
        #expect(store.load() == MachineList())
        store.save(three())
        #expect(store.load() == three())
    }

    @Test func deviceNames() {
        #expect(MachineList.device(nd) == "nightdrive")
        #expect(MachineList.device(URL(string: "https://MacBook.tail1.ts.net/ferry/")!) == "macbook")
        #expect(MachineList.device(URL(string: "http://127.0.0.1:47271/ferry/")!) == nil)   // the mock computers
    }

    @Test func forgetDevices() {
        var l = three()
        l.forget(devices: ["nightdrive", "mini", "nobody"])
        #expect(l.machines.map(\.url) == [mac])
        #expect(l.setup?.url == mac)
    }
}
