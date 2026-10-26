import Foundation
import Testing
@testable import FerryKit

/// Stands in for the background uploader: records what it was given, and fails when told to.
actor FakeFileSender: FileSender {
    private(set) var sends: [(machine: URL, files: [Upload])] = []
    var failWith: FerryError?
    /// How many files arrive before the failure
    var deliverFirst = 0
    func setFail(_ e: FerryError?, after delivered: Int = 0) { failWith = e; deliverFirst = delivered }

    func send(_ files: [Upload], to machine: URL, machineName: String,
              progress: @escaping @Sendable (Double) -> Void, delivered: @escaping @Sendable (Upload) -> Void) async throws {
        sends.append((machine, files))
        if let failWith {
            files.prefix(deliverFirst).forEach(delivered)
            throw failWith
        }
        files.forEach(delivered)
        progress(1)
    }
}

private let a = URL(string: "https://a.tail1.ts.net/ferry/")!
private let b = URL(string: "https://b.tail1.ts.net/ferry/")!

@MainActor @Suite struct ShareModelTests {
    let fake = FakeBackend()
    let files = FakeFileSender()

    func known(_ urls: [URL]) -> [KnownMachine] {
        var list = MachineList()
        for (i, u) in urls.enumerated() { list.add(u, name: u == a ? "A" : "B", at: t0, asSetup: i == 0) }
        return list.machines
    }

    func share(_ payloads: [SendPayload], machines: [URL] = [a, b], settle: Duration = .milliseconds(40)) async -> ShareModel {
        await fake.set(a, name: "A", idle: 600)
        await fake.set(b, name: "B", idle: 1200)
        return ShareModel(machines: known(machines), payloads: payloads, ask: fake, send: fake, files: files, settle: settle)
    }

    let text = SendPayload.text("hello", clip: false)
    let photo = SendPayload.file(URL(filePath: "/tmp/p.jpg"), name: "p.jpg", type: "image/jpeg", clip: false)

    func asks() async -> [String] { await fake.calls.filter { $0.hasPrefix("items") } }
    func sends() async -> [String] { await fake.calls.filter { $0.hasPrefix("send") } }

    @Test func noMachines() async {
        let m = await share([text], machines: [])
        await m.start()
        #expect(m.state == .noMachine)
        #expect(await fake.calls.isEmpty)
    }

    @Test func noPayloads() async {
        let m = await share([])
        await m.start()
        #expect(m.state == .nothingToSend)
        #expect(await fake.calls.isEmpty)
    }

    @Test func oneMachineTextGoesWithoutAsking() async {
        let m = await share([text], machines: [a])
        await m.start()
        #expect(m.state == .sent(to: "A"))
        #expect(await asks().isEmpty)
        #expect(await sends() == ["send a.tail1.ts.net"])
    }

    @Test func oneMachineFileAsksFirst() async {
        let m = await share([photo], machines: [a])
        await m.start()
        #expect(m.state == .sent(to: "A"))
        #expect(await asks() == ["items a.tail1.ts.net"])
        #expect(await files.sends.map(\.machine) == [a])
        #expect(await files.sends.first?.files == [Upload(file: URL(filePath: "/tmp/p.jpg"), name: "p.jpg", type: "image/jpeg")])
    }

    @Test func oneMachineFileDownFails() async {
        let m = await share([photo], machines: [a])
        await fake.setDown([a])
        await m.start()
        #expect(m.state == .failed("Can't reach A"))
        #expect(await files.sends.isEmpty)
    }

    @Test func onlyOneAnswersIsSentThere() async {
        let m = await share([text])
        await fake.setDown([b])
        await m.start()
        #expect(m.state == .sent(to: "A"))
        #expect(await sends() == ["send a.tail1.ts.net"])
    }

    @Test func aMissGetsASecondAsk() async {
        let m = await share([text])
        await fake.setDown([a])
        await fake.setDownOnce([b])
        await m.start()
        #expect(m.state == .sent(to: "B"))
        #expect(await asks().filter { $0.hasSuffix("b.tail1.ts.net") }.count == 2)
    }

    @Test func severalAnswerWaitForATap() async {
        let m = await share([text])
        await m.start()
        #expect(m.state == .choosing)
        #expect(await sends().isEmpty)
        await m.pick(b)
        #expect(m.state == .sent(to: "B"))
        #expect(await sends() == ["send b.tail1.ts.net"])
    }

    @Test func noneAnswer() async {
        let m = await share([text])
        await fake.setDown([a, b])
        await m.start()
        #expect(m.state == .failed("Can't reach your computers. Is Tailscale on?"))
        #expect(m.rows.allSatisfy { $0.reply == .unreachable })
        #expect(m.rows.map(\.subtitle) == ["can't reach", "can't reach"])
        await fake.setDown([b])
        await m.retry()
        #expect(m.state == .sent(to: "A"))
    }

    /// Computers that are awake answer within moments of each other: the one in use goes first whichever came first.
    @Test func answersCloseTogetherAreSorted() async throws {
        let m = await share([text], settle: .milliseconds(300))
        await fake.set(b, name: "B", idle: 0)
        await fake.setSlow(b, .milliseconds(100))
        await m.start()
        #expect(m.rows.map(\.machine.name) == ["B", "A"])
    }

    @Test func orderFreezesAtTheFirstAnswer() async throws {
        let m = await share([text])
        await fake.set(b, name: "B", idle: 0)          // B is the one in use, but answers late
        await fake.setSlow(b, .milliseconds(200))
        #expect(m.rows.isEmpty || m.rows.map(\.machine.name) == ["A", "B"])
        let run = Task { await m.start() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(m.rows.map(\.machine.name) == ["A", "B"])
        #expect(m.rows.map(\.subtitle) == ["used 10 min ago", "asking…"])
        #expect(m.state == .choosing)                  // A can be tapped already
        await run.value
        #expect(m.rows.map(\.machine.name) == ["A", "B"])   // didn't jump above A
        #expect(m.rows[1].subtitle == "in use")
    }

    @Test func tapsThatDoNothing() async throws {
        let m = await share([text])
        await fake.setSlow(b, .milliseconds(200))
        let run = Task { await m.start() }
        try await Task.sleep(for: .milliseconds(80))
        await m.pick(b)                                // still asking
        #expect(m.state == .choosing)
        #expect(await sends().isEmpty)
        await run.value

        let down = await share([text])
        await fake.setDown([b])
        await fake.setSlow(a, .milliseconds(200))
        let run2 = Task { await down.start() }
        try await Task.sleep(for: .milliseconds(80))
        await down.pick(b)                             // can't be reached
        #expect(await sends().isEmpty)
        await run2.value
        #expect(down.state == .sent(to: "A"))
    }

    @Test func aSecondTapWhileSendingSendsNothingMore() async throws {
        let m = await share([photo])
        await m.start()
        await files.setFail(nil)
        let first = Task { await m.pick(a) }
        await m.pick(b)
        await first.value
        #expect(await files.sends.count == 1)
    }

    @Test func lateAnswerAfterAPickSendsNothingMore() async throws {
        let m = await share([text])
        await fake.setSlow(b, .milliseconds(200))
        let run = Task { await m.start() }
        try await Task.sleep(for: .milliseconds(80))
        await m.pick(a)
        #expect(m.state == .sent(to: "A"))
        await run.value                                 // B answers after the send
        #expect(m.state == .sent(to: "A"))
        await m.pick(b)
        #expect(await sends() == ["send a.tail1.ts.net"])
    }

    @Test func textsAndFilesTogether() async {
        let second = SendPayload.file(URL(filePath: "/tmp/q.png"), name: "q.png", type: "image/png", clip: false)
        let m = await share([text, photo, second], machines: [a])
        await m.start()
        #expect(m.sendsFiles)
        #expect(m.state == .sent(to: "A"))
        #expect(await sends() == ["send a.tail1.ts.net"])
        #expect(await files.sends.count == 1)
        #expect(await files.sends.first?.files.map(\.name) == ["p.jpg", "q.png"])
    }

    /// Try again sends what didn't arrive, not again what did (review: a retry resent the files that had arrived).
    @Test func retrySendsOnlyWhatDidntArrive() async {
        let second = SendPayload.file(URL(filePath: "/tmp/q.png"), name: "q.png", type: "image/png", clip: false)
        let m = await share([text, photo, second], machines: [a])
        await files.setFail(.unreachable(machine: "a"), after: 1)
        await m.start()
        #expect(m.state == .failed("Can't reach A"))
        await files.setFail(nil)
        await m.retry()
        #expect(m.state == .sent(to: "A"))
        #expect(await sends() == ["send a.tail1.ts.net"])          // the text went the first time
        #expect(await files.sends.last?.files.map(\.name) == ["q.png"])
    }

    @Test func retryAfterASendFailureGoesToTheSameComputer() async {
        let m = await share([photo])
        await m.start()
        await files.setFail(.unreachable(machine: "b"))
        await m.pick(b)
        #expect(m.state == .failed("Can't reach B"))
        await files.setFail(nil)
        let asked = await asks().count
        await m.retry()
        #expect(m.state == .sent(to: "B"))
        #expect(await asks().count == asked)
        #expect(await files.sends.map(\.machine) == [b, b])
    }

    @Test func theListShowsBeforeTheShareHasLoaded() async throws {
        await fake.set(a, name: "A", idle: 600)
        await fake.set(b, name: "B", idle: 1200)
        await fake.setDown([b])
        let text = text
        let m = ShareModel(machines: known([a, b]), load: {
            try? await Task.sleep(for: .milliseconds(150))   // a big video copied out of Photos
            return [text]
        }, ask: fake, send: fake, files: files)
        #expect(m.rows.map(\.machine.name) == ["A", "B"])
        #expect(m.payloads == nil)
        let run = Task { await m.start() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(m.rows.map(\.subtitle) == ["asking…", "asking…"])
        await run.value
        #expect(m.payloads == [text])
        #expect(m.state == .sent(to: "A"))
    }

    @Test func aShareThatLoadsEmptyHasNothingToSend() async {
        let m = ShareModel(machines: known([a, b]), load: { [] }, ask: fake, send: fake, files: files)
        await m.start()
        #expect(m.state == .nothingToSend)
        #expect(await fake.calls.isEmpty)
    }
}
