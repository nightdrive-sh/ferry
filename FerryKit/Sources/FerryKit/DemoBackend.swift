import Foundation

/// The demo's two pretend computers, inside the app with no network: "Try without a computer" on the setup screen.
/// App Review uses it (guideline 2.1: Ferry does nothing without a computer running Ferry and Tailscale), and so can
/// anyone curious before setting anything up. What the phone sends goes into a box like a computer's, and the first
/// send gets something back, so the received list and its notification can be seen too.
public actor DemoBackend: FerryBackend {
    public static let macBook = URL(string: "https://macbook.demo.invalid/ferry/")!
    public static let desktop = URL(string: "https://desktop.demo.invalid/ferry/")!
    /// What MacBook sends back after the first send.
    public static let reply = "Hello from MacBook! Tap a text to copy it."

    private struct Computer {
        let name: String
        /// Seconds since it was used: MacBook is in use, so it is where a send goes
        let idle: Int
        var items: [Item]
    }

    private var computers: [URL: Computer]
    private let photo: Data
    private let now: @Sendable () -> Date
    private let step: Duration
    private let replyAfter: Duration
    private let onFirstSend: @Sendable () async -> Void
    private let onArrival: @Sendable (Received) async -> Void
    private var replied = false

    /// `photo` is the PNG of the picture MacBook holds (made by the app: FerryKit has no UIKit). `step` paces a send's
    /// progress; `onFirstSend` hears of the first send, and `onArrival` of the reply, `replyAfter` later.
    public init(photo: Data, now: @escaping @Sendable () -> Date = Date.init, step: Duration = .milliseconds(120),
                replyAfter: Duration = .seconds(3), onFirstSend: @escaping @Sendable () async -> Void = {},
                onArrival: @escaping @Sendable (Received) async -> Void = { _ in }) {
        self.photo = photo
        self.now = now
        self.step = step
        self.replyAfter = replyAfter
        self.onFirstSend = onFirstSend
        self.onArrival = onArrival
        let t = now()
        computers = [
            Self.macBook: Computer(name: "MacBook", idle: 0, items: [
                Item(id: "demo-photo", to: .phone, kind: .file, time: t.addingTimeInterval(-4 * 60), name: "screenshot.png",
                     size: Int64(photo.count), type: "image/png"),
            ]),
            Self.desktop: Computer(name: "Desktop", idle: 3600, items: [
                Item(id: "demo-link", to: .phone, kind: .text, time: t.addingTimeInterval(-50 * 60),
                     text: "https://nightdrive.sh/ferry"),
            ]),
        ]
    }

    private func computer(_ machine: URL) throws -> Computer {
        guard let c = computers[MachineList.normalized(machine)] else {
            throw FerryError.unreachable(machine: String(machine.host()?.split(separator: ".").first ?? ""))
        }
        return c
    }

    public func ping(_ machine: URL) async throws -> String { try computer(machine).name }

    public func items(_ machine: URL) async throws -> ItemsResponse {
        let c = try computer(machine)
        return ItemsResponse(computer: c.name, items: c.items, keep: 7, idle: c.idle)
    }

    public func machines(_ machine: URL) async throws -> MachinesResponse {
        let me = MachineList.normalized(machine)
        _ = try computer(me)
        return MachinesResponse(machines: computers.sorted { $0.value.name < $1.value.name }
            .map { MachineInfo(url: $0.key, name: $0.value.name, isSelf: $0.key == me) })
    }

    /// The pretend computers have no other devices to tell
    public func forget(_ device: String, on machine: URL) async throws {}
    public func unforget(_ device: String, on machine: URL) async throws {}
    public func unforgetSelf(on machine: URL) async throws {}

    public func send(_ payload: SendPayload, to machine: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let url = MachineList.normalized(machine)
        _ = try computer(url)
        let item: Item
        switch payload {
        case .text(let text, _):
            try await Task.sleep(for: step)
            item = Item(id: UUID().uuidString, to: .computer, kind: .text, time: now(), text: text, from: "iPhone")
        case .file(let file, let name, let type, _):
            // A file takes a moment, so the bar's progress shows as it would
            for i in 1...5 {
                try await Task.sleep(for: step)
                progress(Double(i) / 5)
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
            item = Item(id: UUID().uuidString, to: .computer, kind: .file, time: now(), name: name, size: size, type: type,
                        from: "iPhone")
        }
        computers[url]?.items.append(item)
        if !replied {
            replied = true
            await onFirstSend()
            Task { [replyAfter] in
                try? await Task.sleep(for: replyAfter)
                await leaveReply()
            }
        }
    }

    private func leaveReply() async {
        let item = Item(id: "demo-reply", to: .phone, kind: .text, time: now(), text: Self.reply)
        computers[Self.macBook]?.items.append(item)
        await onArrival(Received(item: item, machine: Self.macBook, machineName: "MacBook"))
    }

    public func download(_ item: Item, from machine: URL) async throws -> URL {
        _ = try computer(machine)
        guard item.id == "demo-photo", let name = item.name else { throw FerryError.refused(status: 404, message: "Not in the box any more") }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try photo.write(to: file)
        return file
    }

    public func remove(_ id: String, on machine: URL) async throws {
        let url = MachineList.normalized(machine)
        _ = try computer(url)
        computers[url]?.items.removeAll { $0.id == id }
    }

    public func clearReceived(on machine: URL) async throws {
        let url = MachineList.normalized(machine)
        _ = try computer(url)
        computers[url]?.items.removeAll { $0.to == .phone }
    }

    /// Nothing to subscribe: the demo's notification is made by the app itself.
    public func subscribe(_ endpoint: URL, keys: PushKeys, on machine: URL) async throws {}
    public func unsubscribe(_ endpoint: URL, on machine: URL) async throws {}
}
