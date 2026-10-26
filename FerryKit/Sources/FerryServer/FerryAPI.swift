import FerryKit
import Foundation
#if os(macOS)
import CoreServices
#endif

/// docs/protocol.md, call by call: who may ask (bin/ferry's `gate()`, `cors()`), and what each call does.
public struct FerryAPI: Sendable {
    static let gateCopy = "Ferry answers only its computer's owner, through Tailscale."
    static let noPage = "Ferry on this Mac has no web page. Use the Ferry app on your phone."
    /// Shown in the browser (bin/ferry's `INLINE`); any other file is a download, so an HTML or SVG file never runs
    /// as a page
    static func inline(_ kind: String) -> Bool {
        ["image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif", "image/avif", "video/", "audio/"]
            .contains { kind.hasPrefix($0) } || kind == "application/pdf" || kind == "text/plain"
    }

    let config: ServerConfig
    let system: any FerrySystem
    let tailnet: Tailnet
    let box: Box
    let pusher: Pusher
    let forgotten: Forgotten
    let clock: @Sendable () -> TimeInterval
    let machines: @Sendable () async -> [[String: JSONValue]]
    private let grouping = Grouping()

    public init(config: ServerConfig, system: any FerrySystem, tailnet: Tailnet, box: Box, pusher: Pusher, forgotten: Forgotten,
                clock: @escaping @Sendable () -> TimeInterval, machines: @escaping @Sendable () async -> [[String: JSONValue]]) {
        self.config = config
        self.system = system
        self.tailnet = tailnet
        self.box = box
        self.pusher = pusher
        self.forgotten = forgotten
        self.clock = clock
        self.machines = machines
    }

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let path = route(req.path)
        let origin = await cors(req)
        var res: HTTPResponse
        switch req.method {
        case "OPTIONS":
            res = await preflight(req, origin: origin)
        case "GET", "HEAD":
            if let denied = await gate(req, api: path.hasPrefix("/api/") && !path.hasPrefix("/api/file/"), origin: origin) {
                res = denied
            } else {
                res = await get(req, path)
            }
        case "POST":
            if let denied = await gate(req, api: true, origin: origin) {
                res = denied
            } else {
                do { res = try await post(req, path) } catch { res = .text(400, "Bad request") }
            }
        default:
            res = .text(404, "Not found")
        }
        if !res.headers.contains(where: { $0.0 == "Cache-Control" }) { res.headers.append(("Cache-Control", "no-cache")) }
        res.headers.append(("X-Content-Type-Options", "nosniff"))
        if let origin { res.headers += [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")] }
        return res
    }

    /// The path without the mount, in case `tailscale serve` leaves it on (it strips it: see the plan's Task 0)
    func route(_ path: String) -> String {
        if path == config.mount { return "/" }
        return path.hasPrefix(config.mount + "/") ? String(path.dropFirst(config.mount.count)) : path
    }

    // MARK: Who may ask

    /// The asking page's origin when it is on another of the owner's machines (the Linux PWA switched to this one)
    func cors(_ req: HTTPRequest) async -> String? {
        guard let origin = req.headers["Origin"], !origin.isEmpty, await tailnet.sameOwner(origin) else { return nil }
        return origin
    }

    /// nil when the request may go on: only the owner, asking this machine by name, and for the API only a Ferry
    /// client (`X-Ferry`), not another page in the phone's browser
    func gate(_ req: HTTPRequest, api: Bool, origin: String?) async -> HTTPResponse? {
        guard await tailnet.allowed(login: req.headers["Tailscale-User-Login"] ?? ""),
              await tailnet.forMe(host: req.headers["Host"] ?? "") else { return .text(403, Self.gateCopy) }
        let site = req.headers["Sec-Fetch-Site"] ?? "same-origin"
        if api, req.headers["X-Ferry"] != "1" || (site != "same-origin" && site != "none" && origin == nil) {
            return .text(403, "Not from the Ferry page")
        }
        return nil
    }

    func preflight(_ req: HTTPRequest, origin: String?) async -> HTTPResponse {
        guard origin != nil, await tailnet.allowed(login: req.headers["Tailscale-User-Login"] ?? ""),
              await tailnet.forMe(host: req.headers["Host"] ?? "") else { return .text(403, "Not allowed") }
        return HTTPResponse(status: 204, headers: [("Access-Control-Allow-Methods", "GET, POST"),
                                                   ("Access-Control-Allow-Headers", "X-Ferry, Content-Type"),
                                                   ("Access-Control-Max-Age", "600")])
    }

    /// The asking device's tailnet name (tailscale serve gives its address)
    func who(_ req: HTTPRequest) async -> String {
        let ip = (req.headers["X-Forwarded-For"] ?? "").split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let name = await tailnet.device(ip: ip)
        return name.isEmpty ? "your phone" : name
    }

    /// Seconds since this computer was used, as the protocol counts them: 0 while in use
    func idle() async -> JSONValue {
        guard let s = await system.secondsSinceInput() else { return .null }
        return .int(Int64(s < config.idleInUse ? 0 : s))
    }

    // MARK: GET

    func get(_ req: HTTPRequest, _ path: String) async -> HTTPResponse {
        switch path {
        case "/":
            return .text(404, Self.noPage)
        case "/api/ping":
            return .json(["computer": .string(await system.computerName()), "idle": await idle(),
                          "forgotten": await forgottenList()] as [String: JSONValue])
        case "/api/items":
            let items = await box.listed(for: await who(req)).map { JSONValue.object($0.wire) }
            return .json(["computer": .string(await system.computerName()), "items": .array(items),
                          "keep": .int(Int64(config.keepDays)), "idle": await idle(),
                          "push": .string(await pusher.publicKey)] as [String: JSONValue])
        case "/api/machines":
            return .json(["machines": .array(await machines().map(JSONValue.object)),
                          "push": .string(await pusher.publicKey), "forgotten": await forgottenList()] as [String: JSONValue])
        default:
            guard path.hasPrefix("/api/file/") else { return .text(404, "Not found") }
            guard let it = await box.find(id: String(path.dropFirst("/api/file/".count))), it.kind == "file" else {
                return .text(404, "Not in the box any more")
            }
            return file(it, attachment: req.query["download"] == "1")
        }
    }

    /// docs/protocol.md › Forgetting a device: what api/ping and api/machines carry
    func forgottenList() async -> JSONValue {
        .array(await forgotten.all.map { .object(["device": .string($0.device), "time": .double($0.time), "forgotten": .bool($0.forgotten)]) })
    }

    func file(_ it: BoxItem, attachment: Bool) -> HTTPResponse {
        guard let path = it.path, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return .text(404, "The file is gone") }
        let kind = it.type ?? ""
        let shown = Self.inline(kind)
        // Python's urllib.parse.quote: ASCII letters, digits and "-._~/" stay, everything else is %-escaped as UTF-8
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        let quoted = (it.name ?? "file").addingPercentEncoding(withAllowedCharacters: allowed) ?? "file"
        var headers = [("Content-Type", shown ? kind : "application/octet-stream"),
                       ("Content-Disposition", "\(shown && !attachment ? "inline" : "attachment"); filename*=UTF-8''\(quoted)")]
        if kind != "application/pdf" {   // Safari's PDF viewer doesn't open in a sandbox
            headers.append(("Content-Security-Policy", "sandbox; default-src 'none'; img-src 'self'; media-src 'self'"))
        }
        return HTTPResponse(status: 200, headers: headers, body: .file(URL(filePath: path), length: size))
    }

    // MARK: POST

    func json(_ req: HTTPRequest, limit: Int) async throws -> [String: Any] {
        let data = try await req.body.collect(limit: limit)
        guard let d = try JSONSerialization.jsonObject(with: data.isEmpty ? Data("{}".utf8) : data) as? [String: Any] else {
            throw HTTPError.malformed
        }
        return d
    }

    func post(_ req: HTTPRequest, _ path: String) async throws -> HTTPResponse {
        let ok = HTTPResponse.json(["ok": true])
        switch path {
        case "/api/text":
            let body = try await json(req, limit: config.maxText * 2)
            let text = body["text"] as? String ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .text(400, "Empty text") }
            await receivedText(String(text.prefix(config.maxText)), from: await who(req), clip: body["clip"] as? Bool == true)
            return ok
        case "/api/upload":
            return await upload(req)
        case "/api/clear":
            await box.clear(to: req.query["to"] ?? "")
            return ok
        case "/api/remove":
            await box.remove(id: req.query["id"] ?? "")
            return ok
        case "/api/subscribe":
            let body = try await json(req, limit: 8192)
            let keys = body["keys"] as? [String: Any]
            guard let endpoint = body["endpoint"] as? String, endpoint.hasPrefix("https://"),
                  let p256dh = keys?["p256dh"] as? String, !p256dh.isEmpty,
                  let auth = keys?["auth"] as? String, !auth.isEmpty else { return .text(400, "Not a push subscription") }
            // No page here could show a browser's notifications: only the app subscribes on a Mac
            guard body["direct"] as? Bool == true else { return .text(400, "Ferry on this Mac notifies only the Ferry app") }
            // A forgotten device is answered as ever, but gets no notifications from here
            let device = await who(req)
            if await forgotten.ids.contains(device) { return ok }
            await pusher.subscribe(Subscription(endpoint: endpoint, keys: .init(p256dh: p256dh, auth: auth),
                                                device: device, time: clock(), direct: true))
            // Forgotten meanwhile (another request ran between the awaits): the forget's own drop may have come first
            if await forgotten.ids.contains(device) { await pusher.drop(devices: [device]) }
            return ok
        case "/api/forget", "/api/unforget":
            // Forgotten on every computer: the others merge this one's list from its api/ping
            guard let device = try await json(req, limit: 8192)["device"] as? String, Forgotten.isDeviceName(device) else {
                return .text(400, "Not a device's tailnet name")
            }
            await forgotten.decide(device, forget: path == "/api/forget")
            await pusher.drop(devices: await forgotten.ids)
            return ok
        case "/api/unsubscribe":
            await pusher.unsubscribe(endpoint: try await json(req, limit: 8192)["endpoint"] as? String ?? "")
            return ok
        case "/api/relay":
            // The page from the computer at via, switched to this one: notifications go through via
            let via = try await json(req, limit: 8192)["via"] as? String ?? ""
            let own = await tailnet.baseURL(mount: config.mount, httpsPort: config.httpsPort)?.absoluteString
            guard await tailnet.sameOwner(via), via.hasSuffix(config.mount + "/"), via != own else {
                return .text(400, "Not a Ferry page of yours")
            }
            await pusher.addRelay(via)
            return ok
        case "/api/relay-push":
            // Another of the owner's computers notifies this one's phones about itself
            let msg = try await json(req, limit: 8192)
            let machine = msg["machine"] as? String ?? ""
            guard await tailnet.sameOwner(machine) else { return .text(400, "Not a Ferry page of yours") }
            let own = await tailnet.baseURL(mount: config.mount, httpsPort: config.httpsPort)?.absoluteString ?? ""
            await pusher.push(title: String((msg["title"] as? String ?? "").prefix(200)),
                              body: String((msg["body"] as? String ?? "").prefix(300)), machine: machine,
                              device: String((msg["device"] as? String ?? "").prefix(100)), own: own)
            return ok
        default:
            return .text(404, "Not found")
        }
    }

    func upload(_ req: HTTPRequest) async -> HTTPResponse {
        let n = Int64(req.headers["Content-Length"] ?? "") ?? 0
        if n > config.maxFile { return .text(413, "Too big: \(Self.human(config.maxFile)) at most") }
        let dest = system.downloads
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        if let free = system.freeSpace(at: dest), free - n < config.minFree { return .text(507, "Not enough space on the computer") }
        // A name no other upload is writing to at the same time: the .part is created only if it doesn't exist
        var path: URL
        var fd: Int32
        repeat {
            path = FileNames.unique(dest.appending(path: FileNames.safe(req.query["name"] ?? "file")))
            fd = open(path.path + ".part", O_WRONLY | O_CREAT | O_EXCL, 0o644)
        } while fd < 0 && errno == EEXIST
        guard fd >= 0 else { return .text(400, "Upload failed") }
        let part = URL(filePath: path.path + ".part")
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var size: Int64 = 0
        do {
            while let chunk = try await req.body.next() {
                size += Int64(chunk.count)
                if size > config.maxFile { throw HTTPError.tooBig }
                try out.write(contentsOf: chunk)
            }
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: part)
            return .text(400, "Upload failed")
        }
        if FileManager.default.fileExists(atPath: path.path) { path = FileNames.unique(path) }   // taken meanwhile
        guard Darwin.rename(part.path, path.path) == 0 else {
            try? FileManager.default.removeItem(at: part)
            return .text(400, "Upload failed")
        }
        Self.quarantine(path)
        let kind = req.query["type"].flatMap { $0.isEmpty ? nil : $0 } ?? MIME.type(forName: path.lastPathComponent)
        await receivedFile(path, size: size, type: kind, from: await who(req), clip: req.query["clip"] == "1")
        return .json(["ok": .bool(true), "name": .string(path.lastPathComponent)] as [String: JSONValue])
    }

    /// What a device sends often came from someone else (Mail, Messages), so it is marked as downloaded, as AirDrop and
    /// browsers mark theirs: Gatekeeper asks before an app or a script document from it runs
    static func quarantine(_ file: URL) {
        #if os(macOS)
        var url = file
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Ferry",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        try? url.setResourceValues(values)
        #endif
    }

    // MARK: What arrived

    func receivedText(_ text: String, from who: String, clip: Bool) async {
        let secret = Secret.looksLike(text)
        // A code or a password leaves the box once copied, and one on the clipboard is copied already
        let item = BoxItem(id: Box.newID(), to: "computer", kind: "text", time: clock(), text: text, from: who, seen: false)
        if !(clip && secret) { await box.append([item]) }
        // The phone's Clipboard button means "onto this computer's clipboard": no Copy to press. A typed text waits
        // for one, so it doesn't replace what was just copied here.
        // A code or a password isn't shown: Notification Center keeps what a notification says (docs/protocol.md ›
        // Codes and passwords). The phone's clipboard often holds a password from its password manager, so what Send
        // Clipboard puts on this one is kept out of clipboard histories.
        if clip {
            await system.copy(text: text, sensitive: true)
            await system.notify(Notice(id: UUID().uuidString, title: "Copied from \(who)",
                                       body: secret ? Secret.named : String(text.prefix(300)), copied: true))
        } else {
            await system.notify(Notice(id: UUID().uuidString, title: "Text from \(who)",
                                       body: secret ? Secret.hidden : String(text.prefix(300)),
                                       text: secret ? nil : text, item: item.id))
        }
    }

    func receivedFile(_ path: URL, size: Int64, type: String, from who: String, clip: Bool) async {
        let name = path.lastPathComponent
        await box.append([BoxItem(id: Box.newID(), to: "computer", kind: "file", time: clock(), name: name, size: size,
                                  type: type, from: who, seen: false, path: path.path)])
        let folder = path.deletingLastPathComponent().lastPathComponent
        if clip && type.hasPrefix("image/") {
            // An image from the phone's clipboard goes onto this one's too, ready to paste; the file stays in Downloads
            await system.copy(imageAt: path, type: type, sensitive: true)
            await system.notify(Notice(id: UUID().uuidString, title: "Copied \(name)", body: "From \(who) · \(folder)",
                                       files: [path], copied: true))
            return
        }
        let (id, files) = await grouping.add(path, now: clock(), within: config.groupNotify)
        await system.notify(Notice(id: id, title: files.count == 1 ? "Received \(name)" : "Received \(files.count) files",
                                   body: "From \(who) · \(folder)", files: files))
    }

    /// bin/ferry's `human()`
    static func human(_ bytes: Int64) -> String {
        var n = Double(bytes)
        for unit in ["B", "KB", "MB", "GB"] {
            if n < 1000 || unit == "GB" { return unit == "B" ? String(format: "%.0f B", n) : String(format: "%.1f \(unit)", n) }
            n /= 1000
        }
        return ""
    }
}

/// Files from devices within a few seconds of each other share one notification.
actor Grouping {
    private var when: TimeInterval = -.infinity
    private var id = ""
    private var files: [URL] = []

    func add(_ file: URL, now: TimeInterval, within: TimeInterval) -> (id: String, files: [URL]) {
        if now - when >= within {
            id = UUID().uuidString
            files = []
        }
        when = now
        files.append(file)
        return (id, files)
    }
}
