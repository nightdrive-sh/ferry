import FerryKit
import Foundation
import Testing
@testable import FerryServer

/// The Mac's side of forgetting a device: what it learns from the other computers' api/ping, and its device lists.
@Suite struct ForgetServerTests {
    func rig(nightdriveForgot list: String = "[]") async throws -> ServerRig {
        let r = try ServerRig(known: [])
        await r.outbound.set(status: 200, for: "nightdrive.tail1234.ts.net")
        await r.outbound.set(answer: Data(#"{"computer":"Nightdrive","idle":0,"forgotten":\#(list)}"#.utf8),
                             for: "nightdrive.tail1234.ts.net")
        return r
    }

    @Test func learnsFromAnotherComputersPing() async throws {
        let r = try await rig(nightdriveForgot: #"[{"device":"iphone","time":5,"forgotten":true}]"#)
        await r.server.pusher.subscribe(Subscription(endpoint: "https://push.nightdrive.sh/push/a", keys: .init(p256dh: "k", auth: "a"),
                                                     device: "iphone", time: 0, direct: true))
        _ = await r.server.machines()
        #expect(await r.server.forgotten.ids == ["iphone"])
        #expect(await r.server.devices().map(\.id) == ["nightdrive"])
        #expect(await r.server.forgottenDevices().map(\.id) == ["iphone"])
        #expect(await r.server.pusher.subscriptions().isEmpty)   // learnt elsewhere, its subscriptions go here too
    }

    @Test func aForgottenComputerLeavesTheMachinesAndDevices() async throws {
        let r = try await rig()
        _ = await r.server.machines()
        #expect(await r.server.devices().map(\.id) == ["nightdrive", "iphone"])
        await r.server.forget("nightdrive")
        let m = await r.server.machines()
        #expect(m.count == 1)
        #expect(m.first?["self"] == .bool(true))
        #expect(await r.server.devices().map(\.id) == ["iphone"])
        #expect(await r.server.forgottenDevices().map { "\($0.id) \($0.kind)" } == ["nightdrive computer"])
        #expect(await r.server.target()?.id == "iphone")
        await r.server.unforget("nightdrive")
        #expect(await r.server.devices().map(\.id) == ["nightdrive", "iphone"])
        #expect(await r.server.forgottenDevices().isEmpty)
    }

    /// The computer it is forgotten on goes on listing itself: only the others leave it out
    @Test func aComputerNeverForgetsItself() async throws {
        let r = try await rig(nightdriveForgot: #"[{"device":"macbook","time":5,"forgotten":true}]"#)
        let m = await r.server.machines()
        #expect(m.first?["self"] == .bool(true))
        #expect(m.count == 2)
    }

    /// A picked device that was forgotten is no target
    @Test func theTargetMovesOff() async throws {
        let r = try ServerRig()
        await r.server.pick("nightdrive")
        await r.server.forget("nightdrive")
        #expect(await r.server.target()?.id == "iphone")
    }
}
