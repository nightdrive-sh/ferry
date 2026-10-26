import FerryKit
import Foundation

/// What the Mac sends: a text or files. clip: it is the clipboard, so another computer puts it on its own (an image's
/// too, bin/ferry's `clip=1`).
public enum Outgoing: Sendable {
    case text(String, clip: Bool)
    case files([URL], clip: Bool = false)
}

/// A computer running Ferry: the server on localhost, and what the app does with it (send, pick a device, publish).
public actor FerryServer {
    let config: ServerConfig
    let system: any FerrySystem
    let tailscale: any TailscaleCLI
    let outbound: any Outbound
    let clock: @Sendable () -> TimeInterval
    let tailnet: Tailnet
    let box: Box
    let pusher: Pusher
    let found: Found
    let forgotten: Forgotten
    /// Yields when Received changes (something lands, or is removed, cleared or pruned), for the menu bar icon's count
    public nonisolated let receivedChanged: AsyncStream<Void>
    private var http: HTTPServer?
    private var boundPort: UInt16?
    private var chores: [Task<Void, Never>] = []
    /// start() failed: the port is someone else's, so it must never go on the tailnet
    private var failedToStart = false
    /// What Tailscale said when it last refused to publish: it stands until publish(true) is asked again (Try Again)
    private var refused: PublishState?

    public init(config: ServerConfig, system: any FerrySystem, tailscale: any TailscaleCLI,
                outbound: any Outbound = URLSessionOutbound(),
                clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) throws {
        self.config = config
        self.system = system
        self.tailscale = tailscale
        self.outbound = outbound
        self.clock = clock
        tailnet = Tailnet(cli: tailscale, clock: clock)
        let (receivedChanged, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.receivedChanged = receivedChanged
        box = Box(state: config.state, keepDays: config.keepDays, clock: clock, changed: { changed.yield() })
        pusher = Pusher(state: config.state, key: try VAPIDKey.load(orCreateIn: config.state), config: config, outbound: outbound)
        found = Found(config: config, probe: { [config, outbound] host in await Found.probe(host: host, config: config, outbound: outbound) },
                      clock: clock)
        forgotten = Forgotten(state: config.state, clock: clock)
    }

    /// Listens on 127.0.0.1, prunes the box hourly and looks for the other computers now and then. Returns the port.
    public func start() async throws -> UInt16 {
        let api = FerryAPI(config: config, system: system, tailnet: tailnet, box: box, pusher: pusher, forgotten: forgotten, clock: clock,
                           machines: { [weak self] in await self?.machines() ?? [] })
        let http = HTTPServer(port: config.port) { await api.handle($0) }
        let port: UInt16
        do {
            port = try await http.start()
        } catch {
            failedToStart = true
            throw error
        }
        failedToStart = false
        self.http = http
        boundPort = port
        let box = self.box
        let every = config.machinesEvery
        chores = [
            // Every minute: a code or a password leaves the disk within a minute of its 15 (a prune saves only when
            // something goes)
            Task { while !Task.isCancelled { await box.prune(); try? await Task.sleep(for: .seconds(60)) } },
            // A thread that died would leave the list as it was for good, so nothing here throws
            Task { [weak self] in
                while !Task.isCancelled {
                    _ = await self?.machines()
                    try? await Task.sleep(for: .seconds(every))
                }
            },
        ]
        return port
    }

    public func stop() async {
        for c in chores { c.cancel() }
        chores = []
        await http?.stop()
        http = nil
    }

    /// `https://<this Mac>.<tailnet>.ts.net/ferry/`, nil while Tailscale is off
    public func address() async -> URL? {
        await tailnet.baseURL(mount: config.mount, httpsPort: config.httpsPort)
    }

    private var port: UInt16 { boundPort ?? config.port }

    // MARK: Publishing

    /// Settings' Stop publishing, remembered across launches
    private var unpublished: URL { config.state.appending(path: "unpublished") }
    private var stopped: Bool { FileManager.default.fileExists(atPath: unpublished.path) }

    /// What is true now: published whenever tailscale serve has it, even if its user stopped it once
    public func publishState() async -> PublishState {
        let state = await served()
        guard state == .notPublished else { return state }
        if stopped { return .stopped }
        return refused ?? state
    }

    /// Whether tailscale serve publishes Ferry now, whatever its user chose
    private func served() async -> PublishState {
        do {
            let st = TailnetView(statusJSON: try await tailscale.status())
            guard st.running else { return .tailscaleOff }
            let serve = try await tailscale.serveStatus()
            return Publisher.serving(statusJSON: serve, port: port, httpsPort: config.httpsPort, mount: config.mount)
                ? .published : .notPublished
        } catch is TailscaleNotFound {
            return .tailscaleMissing
        } catch {
            return .tailscaleOff
        }
    }

    /// At launch: publishes unless its user stopped it
    public func publishIfWanted() async -> PublishState {
        if failedToStart { return .notPublished }
        // Stopped by its user, or refused by Tailscale: not asked again until its user says so
        return stopped || refused != nil ? await publishState() : await publish(true)
    }

    /// Publishes or stops, and remembers which, so a stop holds after the app starts again
    public func publish(_ on: Bool) async -> PublishState {
        if failedToStart { return .notPublished }
        refused = nil
        if on { try? FileManager.default.removeItem(at: unpublished) }
        let state = await served()
        guard state != .tailscaleMissing, state != .tailscaleOff else { return state }
        if on, state == .published { return state }
        let (ok, output) = await tailscale.serve(on: on, port: port)
        guard ok else {
            let problem = Publisher.problem(output)
            if on { refused = problem }
            return problem
        }
        // Remembered only once it is really off, so "off" is never said of a Mac still reachable
        if !on {
            try? FileManager.default.createDirectory(at: config.state, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: unpublished.path, contents: nil)
        }
        return await publishState()
    }

    // MARK: The other computers and devices

    /// `api/machines`: this Mac first, then the owner's computers that answer as Ferry now and aren't forgotten
    /// (bin/ferry's `Ferry.machines()`). What it finds goes into machines.json for the device list, and what they
    /// forgot into this Mac's list (docs/protocol.md › Forgetting a device).
    public func machines() async -> [[String: JSONValue]] {
        let view = await tailnet.view(force: true)
        let answered = await found.get(online: view.onlineComputers)
        if !(await found.asked).isEmpty {
            let path = config.state.appending(path: "machines.json")
            let known = StateFile.load([KnownComputer].self, path) ?? []
            StateFile.save(Found.merge(known: known, found: answered, ids: view.ids, now: clock()), path)
            if await forgotten.learn(answered.flatMap(\.forgotten)) { await pusher.drop(devices: await forgotten.ids) }
        }
        let gone = await forgotten.ids
        let me: [String: JSONValue] = ["url": .string(await address()?.absoluteString ?? ""),
                                       "name": .string(await system.computerName()), "self": .bool(true)]
        return [me] + answered.filter { !gone.contains($0.id) }.map { ["url": .string($0.url), "name": .string($0.name)] }
    }

    private var known: [KnownComputer] {
        StateFile.load([KnownComputer].self, config.state.appending(path: "machines.json")) ?? []
    }

    public func devices() async -> [Device] {
        Devices.list(view: await tailnet.view(), known: known, forgotten: await forgotten.ids)
    }

    /// The devices the owner forgot that are still on the tailnet, to bring back
    public func forgottenDevices() async -> [Device] {
        Devices.list(view: await tailnet.view(), known: known, forgotten: await forgotten.ids, forgottenOnes: true)
    }

    /// Off every computer's and phone's lists (the others learn it from this Mac's api/ping), its subscriptions here
    /// gone with it
    public func forget(_ id: String) async {
        await forgotten.decide(id, forget: true)
        await pusher.drop(devices: await forgotten.ids)
    }

    /// Back on the lists: a phone subscribes again by itself
    public func unforget(_ id: String) async {
        await forgotten.decide(id, forget: false)
    }

    /// How many push subscriptions phones made here: one more means a phone was added (bin/ferry's listing's `push`)
    public func phones() async -> Int {
        await pusher.subscriptions().count
    }

    /// The device sends go to: the one picked last, else a phone
    public func target() async -> Device? {
        let picked = (try? String(contentsOf: config.state.appending(path: "target"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Devices.target(await devices(), picked: picked)
    }

    public func pick(_ id: String) {
        try? FileManager.default.createDirectory(at: config.state, withIntermediateDirectories: true)
        try? Data((id + "\n").utf8).write(to: config.state.appending(path: "target"), options: .atomic)
    }

    // MARK: Sending

    /// Sends to one device: into the box for a phone, with a notification, or straight to another computer. nil when
    /// it went, else why not. progress gets the fraction of the files' bytes sent to a computer; anything else reports
    /// only its end.
    public func send(_ what: Outgoing, to device: Device, progress: @escaping @Sendable (Double) -> Void = { _ in }) async
        -> String? {
        switch what {
        case .files(let urls, let clip):
            let files = Devices.files(urls)
            guard !files.isEmpty else { return "No files to send there" }
            if device.kind == .computer { return await deliver(files: files, clip: clip, to: device, progress: progress) }
            let error = await leave(files: files, for: device)
            if error == nil { progress(1) }
            return error
        case .text(let text, let clip):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Nothing to send" }
            let cut = String(text.prefix(config.maxText))
            let error = device.kind == .computer ? await deliver(text: cut, clip: clip, to: device) : await leave(text: cut, for: device)
            if error == nil { progress(1) }
            return error
        }
    }

    private func leave(text: String, for device: Device) async -> String? {
        let item = BoxItem(id: Box.newID(), to: "phone", kind: "text", time: clock(), text: text, for: device.id)
        await box.append([item])
        await notify(String(text.prefix(180)), item: item, device: device)
        return nil
    }

    private func leave(files: [URL], for device: Device) async -> String? {
        var left: [BoxItem] = []
        for f in files {
            guard let it = try? await box.leaveFile(f, for: device.id) else { return "Couldn't read \(f.lastPathComponent)" }
            left.append(it)
        }
        await notify(left.count == 1 ? left[0].name ?? "" : "\(left.count) files", item: left[0], device: device)
        return nil
    }

    private func notify(_ body: String, item: BoxItem, device: Device) async {
        await pusher.push(title: await system.computerName(), body: body, item: item, device: device.id,
                          own: await address()?.absoluteString ?? "")
    }

    private func deliver(text: String, clip: Bool, to device: Device) async -> String? {
        guard let base = known.first(where: { $0.id == device.id }).flatMap({ URL(string: $0.url) }) else {
            return "\(device.name) isn't running Ferry"
        }
        var req = URLRequest(url: base.appending(path: "api/text"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("1", forHTTPHeaderField: "X-Ferry")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "clip": clip])
        return answered(try? await outbound.data(req), device)
    }

    private func deliver(files: [URL], clip: Bool, to device: Device, progress: @escaping @Sendable (Double) -> Void) async
        -> String? {
        guard let base = known.first(where: { $0.id == device.id }).flatMap({ URL(string: $0.url) }) else {
            return "\(device.name) isn't running Ferry"
        }
        // Each file counts by its size, so one big video isn't a quarter of the bar
        let sizes = files.map { Double((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let total = max(sizes.reduce(0, +), 1)
        var before = 0.0
        for (f, size) in zip(files, sizes) {
            // The iPhone app's own request, so a computer sees the Mac's uploads exactly as the phone's
            var req = HTTPBackend.uploadRequest(base, name: f.lastPathComponent, type: MIME.type(forName: f.lastPathComponent),
                                                clip: clip)
            req.timeoutInterval = 30
            let done = before
            let sent = try? await outbound.upload(req, file: f) { p in progress((done + p * size) / total) }
            if let error = answered(sent, device) { return error }
            before += size
        }
        return nil
    }

    private func answered(_ result: (status: Int, body: Data)?, _ device: Device) -> String? {
        guard let result, (200..<300).contains(result.status) else {
            return "\(device.name) didn't answer: it's asleep, or Ferry is off there"
        }
        return nil
    }

    // MARK: The menu

    /// What arrived from devices, newest first
    public func received() async -> [BoxItem] {
        await box.items().filter { $0.to == "computer" }.reversed()
    }

    public func markSeen() async {
        await box.markSeen()
    }

    /// Received items not yet seen in the menu
    public func unseen() async -> Int {
        await received().count { $0.seen != true }
    }

    /// Off the list; a received file stays in Downloads
    /// A text copied on this computer (the popover, a notification): a code or a password leaves the box
    public func copied(id: String) async {
        await box.copied(id: id)
    }

    public func remove(id: String) async {
        await box.remove(id: id)
    }

    /// Empties Received; the files stay in Downloads
    public func clearReceived() async {
        await box.clear(to: "computer")
    }
}
