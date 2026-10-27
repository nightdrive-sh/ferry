import FerryKit
import Foundation
import Testing
@testable import FerryServer

/// The Mac's side of forgetting a device: what it learns from the other computers' api/ping, and its device lists.
@Suite struct ForgetServerTests {
    func rig(nightdriveForgot list: String = "[]", port: UInt16? = nil) async throws -> ServerRig {
        let r = try ServerRig(known: [], port: port)
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
        #expect(await r.server.target()?.id == "iphone")
        await r.server.forgotten.decide("nightdrive", forget: false)   // its Ferry started, or a phone added it again
        #expect(await r.server.devices().map(\.id) == ["nightdrive", "iphone"])
    }

    /// The computer it is forgotten on goes on listing itself: only the others leave it out
    @Test func aComputerNeverForgetsItself() async throws {
        let r = try await rig(nightdriveForgot: #"[{"device":"macbook","time":5,"forgotten":true}]"#)
        let m = await r.server.machines()
        #expect(m.first?["self"] == .bool(true))
        #expect(m.count == 2)
    }

    /// docs/protocol.md › Forgetting a device: a computer's Ferry starting brings it back, once it has asked the others
    /// api/ping, so a forget it learns from them in that round is undone too
    @Test func aComputerComesBackWhenItsFerryStarts() async throws {
        let r = try await rig(nightdriveForgot: #"[{"device":"macbook","time":5,"forgotten":true}]"#, port: 0)
        _ = await r.server.machines()   // learnt before it started: forgotten, as far as a running Ferry goes
        #expect(await r.server.forgotten.ids == ["macbook"])
        _ = try await r.server.start()
        #expect(await until { await r.server.forgotten.ids.isEmpty })
        // The other computer's older forget doesn't win over it
        _ = await r.server.machines()
        #expect(await r.server.forgotten.ids.isEmpty)
        // Only once per start: a forget learnt later holds
        await r.server.forget("macbook")
        _ = await r.server.machines()
        #expect(await r.server.forgotten.ids == ["macbook"])
        // and ends when it starts again
        await r.server.stop()
        _ = try await r.server.start()
        #expect(await until { await r.server.forgotten.ids.isEmpty })
        await r.server.stop()
    }

    @Test func aComputerComesBackWhenNoOtherAnswers() async throws {
        let r = try ServerRig(known: [], port: 0)
        await r.outbound.set(down: "nightdrive.tail1234.ts.net")
        await r.server.forget("macbook")
        await r.server.forget("studio")
        _ = try await r.server.start()
        #expect(await until { await r.server.forgotten.ids == ["studio"] })
        await r.server.stop()
    }

    /// Without start(), no round is the first after a start: a forgotten computer stays so
    @Test func noComingBackWithoutAStart() async throws {
        let r = try await rig(nightdriveForgot: #"[{"device":"macbook","time":5,"forgotten":true}]"#)
        _ = await r.server.machines()
        _ = await r.server.machines()
        #expect(await r.server.forgotten.ids == ["macbook"])
    }

    /// A picked device that was forgotten is no target
    @Test func theTargetMovesOff() async throws {
        let r = try ServerRig()
        await r.server.pick("nightdrive")
        await r.server.forget("nightdrive")
        #expect(await r.server.target()?.id == "iphone")
    }
}

/// Waits until ok is true, for at most 3 s: for what a server's own chores do
func until(_ ok: @Sendable () async -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < end {
        if await ok() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await ok()
}
