import FerryKit
import UIKit
import SwiftUI

@main
struct FerryApp: App {
    static let appGroup = "group.fi.feature.ferry"
    /// The simulator's stand-in computers (tools/mock-ferry.py), used with the launch argument -mock.
    static let mockMachine = URL(string: "http://127.0.0.1:47271/ferry/")!
    static let poll: Duration = .seconds(5)            // the PWA's POLL

    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: FerryModel
    @State private var push: PushCenter
    /// "Try without a computer": while set, the app runs on its pretend computers instead of `model`
    @State private var demo: Demo?
    @State private var settings = false
    @State private var pasteHelp = false
    @State private var askNotifications = false
    /// nightdrive.sh's add page opened before setup: setup connects to its computer
    @State private var setupLink: OpenedLink?
    /// The same once set up: Add a Computer over the app, connecting to it
    @State private var addLink: OpenedLink?
    /// A share view over the app (DEBUG launch arguments -shareText and -shareImage, for the UI tests)
    @State private var shareModel: ShareModel?
    /// The paste permission help shows once, after the first Send Clipboard (iOS lists the setting only after a read)
    @AppStorage("pasteHelpSeen") private var pasteHelpSeen = false
    /// Notifications are offered once, after setup (or on the first launch of a phone set up before they existed)
    @AppStorage("notificationsAsked") private var notificationsAsked = false
    @Environment(\.scenePhase) private var phase

    init() {
        let defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        // Downloads and picked files from the last run: nothing in tmp outlives the run that made it
        let tmp = FileManager.default.temporaryDirectory
        for f in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
        // Copies of shared files whose upload ended unheard: every upload has ended within its hour by then
        if let uploads = UploadCopies.folder(appGroup: Self.appGroup) {
            UploadCopies.prune(uploads, olderThan: 2 * 3600, now: .now)
        }
        #if DEBUG
        // -reset starts over as a fresh install (the UI tests use it)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-reset") {
            defaults.dictionaryRepresentation().keys.forEach(defaults.removeObject(forKey:))
        }
        // -seedClipboard TEXT / -seedClipboardImage: the UI tests' clipboard, put there by the app itself. Copied by
        // another app (the test runner), reading it would stop at iOS's Paste prompt, which blocks the app until answered.
        if let i = args.firstIndex(of: "-seedClipboard"), i + 1 < args.count {
            UIPasteboard.general.string = args[i + 1]
        }
        // -seedMachines: MacBook (setup) and Nightdrive as the mock's, set up without asking them, for tests where
        // they don't answer
        if args.contains("-seedMachines") {
            var list = MachineList()
            list.add(Self.mockMachine, name: "MacBook", at: .now, asSetup: true)
            list.add(URL(string: "http://127.0.0.1:47272/ferry/")!, name: "Nightdrive", at: .now, asSetup: false)
            MachineStore(defaults: defaults).save(list)
        }
        if args.contains("-emptyClipboard") { UIPasteboard.general.items = [] }
        // -shareText TEXT / -shareImage: the share view over the app, made as the share extension makes it
        var shared: [Shared] = []
        if let i = args.firstIndex(of: "-shareText"), i + 1 < args.count { shared.append(.text(args[i + 1])) }
        if args.contains("-shareImage") {
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let file = folder.appending(path: "share.png")
            let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).pngData { c in
                UIColor.systemPink.setFill()
                c.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: file)
            shared.append(.file(file))
        }
        if !shared.isEmpty { _shareModel = State(initialValue: ShareSetup.model { [shared] in shared }) }
        if args.contains("-seedClipboardImage") {
            UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { c in
                UIColor.systemPurple.setFill()
                c.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
        }
        #endif
        // The files the computers sent stay in Caches while their items are in the boxes (iOS may empty it if space
        // runs out), unlike tmp, which is emptied above on every launch
        let files = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Files")
        let model = FerryModel(backend: HTTPBackend(), store: MachineStore(defaults: defaults), cache: FileCache(directory: files))
        let push = PushCenter(model: model, defaults: defaults)
        PushCenter.current = push
        push.start()
        _model = State(initialValue: model)
        _push = State(initialValue: push)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if active.isSetUp {
                    MainView(model: active, toast: push.toast, openSettings: { settings = true },
                             leaveDemo: demoLeave, demo: demo, bar: {
                        SendBar(model: active) { if !pasteHelpSeen { pasteHelp = true } }
                    })
                } else {
                    SetupView(model: model, link: setupLink, done: { setupLink = nil }, tryDemo: startDemo)
                }
            }
            .tint(Theme.primary)
            // Add Device's QR code, scanned with the Camera: the universal link to nightdrive.sh's add page
            .onOpenURL(perform: opened)
            .sheet(item: $addLink) { link in
                SetupView(model: model, adding: true, link: link) { addLink = nil }
            }
            .sheet(isPresented: $settings) {
                SettingsView(model: active, push: push, leaveDemo: demoLeave)
            }
            .sheet(isPresented: $askNotifications) {
                NotificationsPrompt {
                    askNotifications = false
                    notificationsAsked = true
                    Task { await push.requestPermission() }
                } notNow: {
                    askNotifications = false
                    notificationsAsked = true
                }
            }
            // After setup, or on coming into the demo, whose reply is a notification too
            .onChange(of: active.isSetUp, initial: true) { _, setUp in
                if setUp, !notificationsAsked { askNotifications = true }
            }
            .onChange(of: demo?.model.isSetUp) { _, setUp in
                if setUp == false { leaveDemo() }   // every pretend computer forgotten in Settings
            }
            .sheet(isPresented: Binding(get: { shareModel != nil }, set: { if !$0 { shareModel = nil } })) {
                if let share = shareModel {
                    ShareView(model: share) {
                        ShareSetup.uploader.detach()
                        shareModel = nil
                    }
                        .task { await share.start() }
                }
            }
            .sheet(isPresented: $pasteHelp, onDismiss: { pasteHelpSeen = true }) {
                PasteHelpView { pasteHelp = false }.presentationDetents([.medium, .large])
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("-mock"), !model.isSetUp {
                    try? await model.setUp(Self.mockMachine)
                }
            }
            // Restarted only between background and foreground: Control Center or the app switcher (inactive) would
            // otherwise cancel a poll in flight every time
            .task(id: "\(phase == .background) \(demo == nil)") { await poll() }
            .onChange(of: phase) { _, now in
                if now == .active { Task { await push.refreshAuthorization() } }
            }
        }
    }

    /// nightdrive.sh's add page with a computer's address: the computer is set up, or added beside the others. The demo
    /// is left for it, since its computers are pretend.
    private func opened(_ url: URL) {
        guard SetupAddress.isLink(url) else { return }
        let link = OpenedLink(url: url)
        if demo != nil { leaveDemo() }
        guard model.isSetUp else { return setupLink = link }
        // One sheet at a time: whatever is up goes down first, and Add a Computer comes once it has
        let covered = settings || askNotifications || pasteHelp || shareModel != nil || addLink != nil
        settings = false
        askNotifications = false
        pasteHelp = false
        shareModel = nil
        addLink = nil
        guard covered else { return addLink = link }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            addLink = link
        }
    }

    /// The computers in use: the demo's pretend ones while it runs.
    private var active: FerryModel { demo?.model ?? model }

    /// The views' way out of the demo, nil outside it.
    private var demoLeave: (() -> Void)? {
        guard demo != nil else { return nil }
        return leaveDemo
    }

    private func startDemo() {
        Task {
            let started = await Demo.start(sent: { demo?.sent() }, arrived: { r in await demoArrived(r) })
            push.demo = started.model
            demo = started
        }
    }

    private func leaveDemo() {
        demo?.leave()
        push.demo = nil
        demo = nil
        settings = false
    }

    /// The demo's MacBook sent something: it shows in Received at once, and as a notification.
    private func demoArrived(_ r: Received) async {
        guard let demo else { return }   // left before it came
        await demo.model.refresh()
        await push.notifyDemo(r)
        demo.answered()
    }

    /// While the app is on screen: every computer and the machine list at once, then a round every 5 s
    /// (FerryModel.poll: the computers that answer, and the sleeping ones found awake again).
    private func poll() async {
        let model = active
        guard phase != .background else { return model.markAllSeen() }
        await model.refreshAll()
        await push.sync()
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.poll)
            guard !Task.isCancelled else { return }
            await model.poll()
            await push.sync()
        }
    }
}
