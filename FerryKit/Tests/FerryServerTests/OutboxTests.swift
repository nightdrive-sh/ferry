import FerryKit
import Foundation
import Testing
@testable import FerryServer

/// Sends that wait for a computer that is asleep or off (docs/protocol.md › Clients › Sends that wait), and the
/// "awake" push.
@Suite struct OutboxTests {
    static let nightdrive = "nightdrive.tail1234.ts.net"

    /// A rig whose Nightdrive didn't answer one text, now waiting
    func waitingRig(_ clock: TestClock = TestClock(), text: String = "https://example.com", clip: Bool = false) async throws
        -> ServerRig {
        let r = try ServerRig(clock: clock)
        await r.outbound.set(down: Self.nightdrive)
        #expect(await r.server.send(.text(text, clip: clip), to: try await r.device("nightdrive")) == .waiting)
        return r
    }

    @Test func aComputerTailscaleHasOfflineIsntTried() async throws {
        let studio = KnownComputer(id: "studio", name: "Studio", url: "https://studio.tail1234.ts.net/ferry/", idle: 0, seen: 1)
        let r = try ServerRig(known: [studio])
        #expect(await r.server.send(.text("hi", clip: false), to: try await r.device("studio")) == .waiting)
        #expect(await r.outbound.sent.isEmpty)
        let w = try #require(await r.server.waiting().first)
        #expect((w.device, w.name, w.kind, w.text) == ("studio", "Studio", "text", "hi"))
        #expect(w.until - w.time == 3 * 86400)
    }

    @Test func itGoesWhenTheComputerIsBackWithoutClip() async throws {
        let r = try await waitingRig(clip: true)
        await r.outbound.set(up: Self.nightdrive)
        await r.server.deliverWaiting()
        let sent = try #require(await r.outbound.sent.last)
        #expect(sent.request.url?.absoluteString == "https://nightdrive.tail1234.ts.net/ferry/api/text")
        // Onto the other clipboard later, it would replace what was copied there since: it waits in the box instead
        #expect(try JSONSerialization.jsonObject(with: sent.body) as? [String: AnyHashable] == ["text": "https://example.com", "clip": false])
        #expect(await r.server.waiting().isEmpty)
        #expect(await r.system.notices.last?.title == "Delivered to Nightdrive")
    }

    @Test func oneOnlineButNotTakingItIsAskedAgainAfterAMinute() async throws {
        let clock = TestClock()
        let r = try await waitingRig(clock)
        let before = await r.outbound.sent.count
        await r.outbound.set(up: Self.nightdrive)
        await r.outbound.set(status: 502, for: Self.nightdrive)   // tailscale serve, the computer's Ferry not up yet
        await r.server.deliverWaiting()
        #expect(await r.outbound.sent.count == before + 1)
        clock.advance(30)
        await r.server.deliverWaiting()
        #expect(await r.outbound.sent.count == before + 1)
        await r.outbound.set(status: 201, for: Self.nightdrive)
        clock.advance(31)
        await r.server.deliverWaiting()
        #expect(await r.server.waiting().isEmpty)
    }

    @Test func oneThatRefusesItDropsItAndSaysSo() async throws {
        let r = try await waitingRig()
        await r.outbound.set(up: Self.nightdrive)
        await r.outbound.set(status: 507, for: Self.nightdrive)
        await r.outbound.set(answer: Data("Not enough room".utf8), for: Self.nightdrive)
        await r.server.deliverWaiting()
        #expect(await r.server.waiting().isEmpty)
        let notice = try #require(await r.system.notices.last)
        #expect(notice.title == "Couldn't send to Nightdrive")
        #expect(notice.body == "https://example.com: Not enough room")
    }

    @Test func aRefusedSendIsAFailureNotAWait() async throws {
        let r = try ServerRig()
        await r.outbound.set(status: 413, for: Self.nightdrive)
        await r.outbound.set(answer: Data("Too large".utf8), for: Self.nightdrive)
        #expect(await r.server.send(.text("x", clip: false), to: try await r.device("nightdrive"))
            == .failed("Nightdrive refused it: Too large"))
        #expect(await r.server.waiting().isEmpty)
    }

    @Test func filesWaitAsCopies() async throws {
        let r = try ServerRig()
        await r.outbound.set(down: Self.nightdrive)
        let file = tempFolder().appending(path: "photo.jpg")
        try Data("jpeg".utf8).write(to: file)
        #expect(await r.server.send(.files([file], clip: true), to: try await r.device("nightdrive")) == .waiting)
        try FileManager.default.removeItem(at: file)   // moved or deleted meanwhile: the copy still goes
        let w = try #require(await r.server.waiting().first)
        #expect((w.what, w.size) == ("photo.jpg", 4))
        await r.outbound.set(up: Self.nightdrive)
        await r.server.deliverWaiting()
        let up = try #require(await r.outbound.sent.last)
        #expect(up.request.url?.absoluteString == "https://nightdrive.tail1234.ts.net/ferry/api/upload?name=photo.jpg&type=image/jpeg")
        #expect(up.body == Data("jpeg".utf8))
        #expect(await r.server.waiting().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: r.state.appending(path: "outbox/\(w.id)").path))
    }

    @Test func threeDaysACodeFifteenMinutes() async throws {
        let clock = TestClock()
        let r = try await waitingRig(clock, text: "see you")
        _ = await r.server.send(.text("801566", clip: false), to: try await r.device("nightdrive"))
        #expect(await r.server.waiting().count == 2)
        clock.advance(16 * 60)
        #expect(await r.server.waiting().map(\.text) == ["see you"])
        clock.advance(3 * 86400)
        #expect(await r.server.waiting().isEmpty)
    }

    @Test func cancelledAndForgottenSendsGo() async throws {
        let r = try await waitingRig()
        let w = try #require(await r.server.waiting().first)
        await r.server.cancelWaiting(w.id)
        #expect(await r.server.waiting().isEmpty)
        _ = await r.server.send(.text("again", clip: false), to: try await r.device("nightdrive"))
        await r.server.forgotten.decide("nightdrive", forget: true)
        await r.outbound.set(up: Self.nightdrive)
        let before = await r.outbound.sent.count
        await r.server.deliverWaiting()
        #expect(await r.server.waiting().isEmpty)
        #expect(await r.outbound.sent.count == before)   // nothing goes to a forgotten computer
    }

    @Test func theAwakePushGoesToTheAppsQuietly() async throws {
        let r = try ServerRig()
        #expect(await r.server.pusher.wake(title: "MacBook") == nil)   // no app to tell
        let keys = PushKeys.generate()
        await r.server.pusher.subscribe(Subscription(endpoint: "https://push.nightdrive.sh/push/abc",
                                                     keys: .init(p256dh: keys.p256dh, auth: keys.authString),
                                                     device: "iphone", time: 0, direct: true))
        await r.server.pusher.subscribe(Subscription(endpoint: "https://web.push.apple.com/page",
                                                     keys: .init(p256dh: keys.p256dh, auth: keys.authString),
                                                     device: "ipad", time: 0, direct: nil))
        await r.tailscale.set(serve: Data(#"{"Web":{"macbook.tail1234.ts.net:443":{"Handlers":{"/ferry":{"Proxy":"http://127.0.0.1:47270"}}}}}"#.utf8))
        await r.server.announceAwake()
        let pushes = await r.outbound.sent.filter { $0.request.httpMethod == "POST" && $0.request.url?.path().hasPrefix("/push") == true
            || $0.request.url?.host() == "web.push.apple.com" }
        #expect(pushes.map { $0.request.url?.host() } == ["push.nightdrive.sh"])
        let push = try #require(pushes.first)
        #expect(push.request.value(forHTTPHeaderField: "Urgency") == "very-low")
        #expect(push.request.value(forHTTPHeaderField: "TTL") == "3600")
        let json = try JSONSerialization.jsonObject(with: PushCrypto.decrypt(push.body, with: keys)) as? [String: Any]
        #expect(json?["awake"] as? Bool == true)
        #expect(json?["title"] as? String == "MacBook")
    }
}
