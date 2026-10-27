import AppKit
import FerryServer
import os
import QuickLookThumbnailing
import UserNotifications

/// What the popover shows, and what it asks the server. It refreshes only while the popover is open: with it closed,
/// the count follows the server's receivedChanged and the publish state is checked at launch, on opening and after a wake.
@MainActor @Observable
final class MenuModel {
    enum Page { case main, addDevice }

    enum SendState: Equatable {
        case idle
        /// The fraction sent, nil while unknown
        case sending(Double?)
        /// To the device of this name
        case sent(String)
        /// Why not
        case failed(String)
        /// The clipboard had nothing to send
        case nothing
    }

    private(set) var server: FerryServer?
    /// nil until first known
    var publish: PublishState?
    /// The server couldn't start (e.g. another Ferry holds the port)
    var startError: String?
    var received: [BoxItem] = []
    var devices: [Device] = []
    var target: Device?
    var address: URL?
    /// Received items not yet seen in the popover, for the icon's count
    var unseen = 0
    private(set) var isOpen = false
    var page = Page.main {
        didSet {
            guard page == .addDevice, oldValue != .addDevice else { return }
            phonesAtAdd = nil   // counted afresh, now rather than at the next refresh, so a quick phone isn't missed
            Task { await refresh() }
        }
    }
    /// The server's push subscriptions at Add Device's first refresh: one more means the phone it was showing the code
    /// to has the Mac, and the page goes back to the list
    @ObservationIgnored private var phonesAtAdd: Int?
    var sendState = SendState.idle
    /// Whether macOS lets Ferry notify, read each time the popover opens; nil until then
    var notifications: UNAuthorizationStatus?
    /// Closes the popover, for the open panel and windows that should come in front of it (set by StatusItem)
    @ObservationIgnored var closePopover: () -> Void = {}
    /// Opens it again, to show how a send started outside it went (set by StatusItem)
    @ObservationIgnored var showPopover: () -> Void = {}
    /// Files are being dragged over the icon; the popover's own drop targets track the popover
    private(set) var draggingOverIcon = false
    @ObservationIgnored private var leftIcon: Task<Void, Never>?

    /// Thumbnails of received images, by item id
    private var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var making: Set<String> = []

    /// What Try Again sends again: the same text or files to the same device, not a clipboard that changed since
    @ObservationIgnored private var lastSent: (what: Outgoing, to: Device)?
    @ObservationIgnored private var settling: Task<Void, Never>?

    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// One refresh at a time: the timer, Received's changes and row actions all ask for one
    @ObservationIgnored private var inRefresh = false
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "fi.feature.ferry.mac", category: "menu")

    func start() async {
        startError = nil
        if server == nil {
            let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Ferry")
            do {
                server = try FerryServer(config: ServerConfig(state: state), system: MacSystem(), tailscale: TailscaleCommand())
            } catch {
                startError = error.localizedDescription
                return forceSetup()
            }
        }
        guard let server else { return }
        do {
            _ = try await server.start()
        } catch {
            startError = error.localizedDescription
            return forceSetup()
        }
        listen(to: server)
        publish = await server.publishIfWanted()
        await refresh()
    }

    /// `-setupState missing|off|notPublished|problem|stopped|starting|failed` shows that step whatever the real state,
    /// for screenshots
    private func forceSetup() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "setupState") {
        case "missing": publish = .tailscaleMissing
        case "off": publish = .tailscaleOff
        case "notPublished": publish = .notPublished
        case "problem": publish = .problem(message: "Serve is not enabled on your tailnet.",
                                           link: URL(string: "https://login.tailscale.com/f/serve?node=example"))
        case "stopped": publish = .stopped
        case "starting": publish = nil
        case "failed": startError = "Address already in use"
        default: break
        }
        #endif
    }

    func publish(_ on: Bool) async {
        guard let server else { return }
        publish = await server.publish(on)
        forceSetup()
    }

    func allowNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The count follows what arrives, without asking the server on a timer
    private func listen(to server: FerryServer) {
        listening?.cancel()
        listening = Task {
            for await _ in server.receivedChanged {
                if isOpen { await refresh() } else { unseen = await server.unseen() }
            }
        }
    }

    func opened() {
        isOpen = true
        Task {
            notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            #if DEBUG
            // `-notifications denied|notDetermined` shows that line whatever macOS says, for screenshots
            switch UserDefaults.standard.string(forKey: "notifications") {
            case "denied": notifications = .denied
            case "notDetermined": notifications = .notDetermined
            default: break
            }
            #endif
        }
        refreshing?.cancel()
        refreshing = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Leaving the icon ends its part only after a moment: on the way down to the popover the drag crosses the gap
    /// between them, and the tiles shouldn't flicker back to the list
    func iconDragging(_ on: Bool) {
        leftIcon?.cancel()
        if on {
            draggingOverIcon = true
        } else {
            leftIcon = Task {
                try? await Task.sleep(for: .seconds(0.6))
                if !Task.isCancelled { draggingOverIcon = false }
            }
        }
    }

    func closed() {
        draggingOverIcon = false
        isOpen = false
        refreshing?.cancel()
        refreshing = nil
        page = .main
    }

    func refresh() async {
        // After a failed start the server holds no port, and nothing of it may go on the tailnet
        guard let server, startError == nil, !inRefresh else { return }
        inRefresh = true
        defer { inRefresh = false }
        #if DEBUG
        log.notice("refresh")
        #endif
        var state = await server.publishState()
        // Not on the tailnet, and neither its user nor Tailscale said no: put it there, as at launch
        if state == .notPublished { state = await server.publishIfWanted() }
        publish = state
        address = await server.address()
        devices = await server.devices()
        target = await server.target()
        if isOpen { await server.markSeen() }
        received = await server.received()
        unseen = await server.unseen()
        if page == .addDevice {
            let phones = await server.phones()
            if let before = phonesAtAdd, phones > before { page = .main } else if phonesAtAdd == nil { phonesAtAdd = phones }
        }
        forceSetup()
    }

    // MARK: Sending

    /// Sends at once to the device given, or to the target as last known: never after waiting for a refresh
    func send(_ what: Outgoing, to device: Device? = nil) async {
        guard let server, let device = device ?? target else {
            lastSent = nil   // Try Again must not send an earlier send again
            settle(.failed(String(localized: "No device to send to: add one with Add Device")))
            return
        }
        lastSent = (what, device)
        settling?.cancel()
        sendState = .sending(nil)
        let error = await server.send(what, to: device) { [weak self] fraction in
            Task { @MainActor in
                // A report that comes in after the end changes nothing
                if case .sending = self?.sendState { self?.sendState = .sending(fraction) }
            }
        }
        settle(error.map(SendState.failed) ?? .sent(device.name))
    }

    func retry() async {
        guard let lastSent else { return }
        await send(lastSent.what, to: lastSent.to)
    }

    /// Try Again after a failure, else what is on the clipboard now
    func sendClipboard() async {
        if case .failed = sendState, lastSent != nil { return await retry() }
        guard let what = Pasteboard.outgoing() else { return settle(.nothing) }
        await send(what)
    }

    /// One send at a time: a second would overwrite the first's progress and its Try Again
    var isSending: Bool {
        if case .sending = sendState { return true }
        return false
    }

    func pick(_ device: Device) async {
        target = device
        sendState = .idle
        await server?.pick(device.id)
    }

    /// Settings' Forget: off this Mac's lists and, through the other computers, off every device's
    func forget(_ device: Device) async {
        await server?.forget(device.id)
        await refresh()
    }

    /// A result shows for a moment; a failure stays until the next send, with Try Again
    private func settle(_ state: SendState) {
        sendState = state
        settling?.cancel()
        if case .failed = state { return }
        settling = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { sendState = .idle }
        }
    }

    // MARK: Received

    func copy(_ item: BoxItem) {
        NSPasteboard.general.put(item.text ?? "", concealed: item.isSecret)
        if item.isSecret { Task { await copied(id: item.id) } }
    }

    /// A code or a password leaves the box once copied (docs/protocol.md › Codes and passwords)
    func copied(id: String) async {
        await server?.copied(id: id)
        await refresh()
    }

    /// Copy on a code's or a password's notification, which doesn't keep the text: from the box, while it is there
    func copy(id: String) async {
        guard let item = await server?.received().first(where: { $0.id == id }) else { return }
        copy(item)
    }

    /// The item's file, if it is still there; a file moved or deleted in Finder takes its row away instead
    func file(of item: BoxItem) -> URL? {
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else {
            Task { await refresh() }
            return nil
        }
        return URL(filePath: path)
    }

    func remove(_ item: BoxItem) async {
        await server?.remove(id: item.id)
        await refresh()
    }

    func clear() async {
        await server?.clearReceived()
        await refresh()
    }

    /// An image's thumbnail, made once in the background; nil until it is ready
    func thumbnail(for item: BoxItem) -> NSImage? {
        if let image = thumbnails[item.id] { return image }
        // The rows show a thumbnail only for an image: making one for a video or a PDF would be wasted
        guard (item.type ?? "").hasPrefix("image/"), let path = item.path, !making.contains(item.id) else { return nil }
        making.insert(item.id)
        let request = QLThumbnailGenerator.Request(fileAt: URL(filePath: path), size: CGSize(width: 36, height: 36), scale: 2,
                                                   representationTypes: .thumbnail)
        Task {
            do {
                thumbnails[item.id] = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            } catch {
                log.notice("thumbnail \(path, privacy: .public): \(error, privacy: .public)")
            }
        }
        return nil
    }

    /// Only whether Ferry is on the tailnet: at a wake, when the popover is closed
    func checkPublished() async {
        guard let server, startError == nil else { return }
        publish = await server.publishState()
        forceSetup()
    }
}
