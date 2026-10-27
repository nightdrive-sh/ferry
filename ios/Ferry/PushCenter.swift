import FerryKit
import Observation
import UIKit
import UserNotifications

/// A short line the main screen shows for a moment ("Copied"). Its own id, so the same text twice shows twice.
struct Toast: Equatable {
    let id = UUID()
    let text: String
}

/// The app's notifications: permission, the APNs token, keeping every computer subscribed through the relay, and taps.
@MainActor @Observable final class PushCenter: NSObject {
    /// The one the app delegate hands the device token to.
    static var current: PushCenter?

    static let relay: URL = {
        #if DEBUG
        // -relay URL: the local relay the UI tests start (ios/uitest.sh)
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-relay"), i + 1 < args.count, let url = URL(string: args[i + 1]) { return url }
        #endif
        return URL(string: "https://push.nightdrive.sh/")!
    }()

    /// Which APNs host the token belongs to, from how the build was signed: a development profile says
    /// `aps-environment development`; TestFlight and the App Store carry no profile in the app and use production.
    /// Not Debug vs Release: a Release build installed from Xcode is signed for development too.
    static let environment: APNsEnvironment = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .production }
        let text = String(decoding: data, as: UTF8.self)   // a signed plist: the XML is readable in the middle
        guard let key = text.range(of: "<key>aps-environment</key>"),
              let value = text[key.upperBound...].range(of: "<string>development</string>"),
              text[key.upperBound..<value.lowerBound].allSatisfy(\.isWhitespace) else { return .production }
        return .sandbox
    }()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var enabled: Bool
    var toast: Toast?

    let registrar: PushRegistrar
    private let model: FerryModel
    /// The demo's model while it runs: a tap opens its items, and nothing is subscribed (its computers are pretend).
    var demo: FerryModel?
    /// model.setUps when last synced: a change means the phone was added again, maybe after being forgotten
    private var setUps = 0

    init(model: FerryModel, defaults: UserDefaults) {
        self.model = model
        registrar = PushRegistrar(relay: HTTPRelay(base: Self.relay), backend: HTTPBackend(),
                                  store: PushStore(defaults: defaults), keys: { try PushKeychain().loadOrCreate() })
        enabled = registrar.state.enabled
        super.init()
    }

    /// From the app's init: the delegate has to be in place before launching ends, or the tap that launched the app is
    /// never delivered. Registering again on every launch is Apple's advice (the token can change).
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // No Copy action: iOS doesn't let a notification action write the clipboard (it ran Ferry in the background,
        // and the clipboard stayed as it was on a real iPhone, locked or not; only the simulator allowed it). Tapping
        // copies instead. The empty list also removes the action from phones that had build 38.
        center.setNotificationCategories([])
        Task { await refreshAuthorization() }
    }

    /// On launch and whenever Ferry comes back to the screen: the permission may have changed in iOS Settings (the
    /// "Allow in Settings" button leads there), and the switch and the registration follow it.
    func refreshAuthorization() async {
        let before = authorization
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        // Allowed in iOS Settings after a no: that was the way to turn them on, so Ferry's switch needn't be flipped too
        if before == .denied, authorization == .authorized, !enabled { return await setEnabled(true) }
        if enabled, authorization == .authorized { register() }
    }

    func requestPermission() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if granted { await setEnabled(true) }
    }

    /// Settings › Notifications. Off deletes the relay addresses and unsubscribes on every computer.
    func setEnabled(_ on: Bool) async {
        if on, authorization == .notDetermined { return await requestPermission() }
        guard !on || authorization == .authorized else { return }
        enabled = on
        await registrar.setEnabled(on)
        if on { register() }
    }

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            await registrar.setToken(hex, env: Self.environment)
            await sync()
        }
    }

    /// After every poll: the planner usually finds nothing to do, and a computer that just answered gets subscribed.
    func sync() async {
        guard demo == nil else { return }
        if model.setUps != setUps {
            setUps = model.setUps
            registrar.subscribeAgain()
        }
        await registrar.sync(known: model.pushKeys, reachable: model.reachableMachines)
    }

    private func register() {
        #if DEBUG
        // -fakeToken: the simulator's own APNs token isn't needed, as the local relay hands pushes over with simctl
        if ProcessInfo.processInfo.arguments.contains("-fakeToken") {
            return didRegister(deviceToken: Data(repeating: 0xab, count: 32))
        }
        #endif
        UIApplication.shared.registerForRemoteNotifications()
    }

    fileprivate func arrivedWhileOpen() async { await (demo ?? model).refresh() }

    /// What the demo's MacBook sent back, as a notification, if notifications are on.
    func notifyDemo(_ r: Received) async {
        guard enabled, authorization == .authorized else { return }
        await Demo.notify(r)
    }

    /// What the extension opened; or, when it didn't get to (its time ran out, or the simulator, which doesn't run
    /// extensions for simulated pushes), the encrypted payload opened here.
    fileprivate func tapped(_ info: [AnyHashable: Any]) async {
        if let notice = info["notice"] as? [String: Any] { return await open(notice) }
        guard let keys = PushKeychain().load(), let n = PushNotice.open(info, keys: keys) else {
            await model.refreshWaking()
            return
        }
        var notice: [String: Any] = ["address": n.address, "machine": n.message.machine]
        if let id = n.message.id { notice["id"] = id }
        if let kind = n.message.kind { notice["kind"] = kind.rawValue }
        if let text = n.message.text { notice["text"] = text }
        await open(notice)
    }

    /// A tapped notification: Ferry opens at the item, and a text goes on the clipboard.
    private func open(_ notice: [String: Any]) async {
        let machine = (notice["address"] as? String).flatMap(registrar.machine(forAddress:))
        let result = await (demo ?? model).openNotice(machine: machine, id: notice["id"] as? String,
                                            kind: (notice["kind"] as? String).flatMap(Item.Kind.init(rawValue:)),
                                            text: notice["text"] as? String)
        switch result {
        case .copy(let text):
            Pasteboard.copy(text)
            toast = Toast(text: String(localized: "Copied"))
        case .unreachable(let name):
            toast = Toast(text: String(localized: "Couldn't reach \(name)"))
        case .shown, .gone:
            break
        }
    }
}

extension PushCenter: UNUserNotificationCenterDelegate {
    // The completion-handler forms, called back on the main actor: the async forms hand UIKit its completion off the
    // main thread, and UIKit's snapshot update after a tap asserts on that (a crash on every tap).

    /// While Ferry is open there is no banner: the item shows in Received, fetched now rather than at the next poll.
    /// The demo's shows anyway, since it is there to be seen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isDemo = notification.request.content.userInfo["demo"] as? Bool == true
        nonisolated(unsafe) let done = done
        Task { @MainActor in
            if isDemo { return done([.banner, .list, .sound]) }
            done([])
            await arrivedWhileOpen()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        nonisolated(unsafe) let info = response.notification.request.content.userInfo   // plist values, read on the main actor
        nonisolated(unsafe) let done = done
        Task { @MainActor in
            await tapped(info)
            done()
        }
    }
}

/// Hands APNs' answers to PushCenter; SwiftUI has no other way to receive them.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.current?.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Quiet: without a token there is nothing to register, and the next launch asks again
    }

    /// A share's background upload ended while its extension was gone
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.identifier else { return completionHandler() }
        ShareUploads.shared.reconnect(completion: completionHandler)
    }
}
