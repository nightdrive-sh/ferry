import AppKit
import SwiftUI

/// Ferry for Mac: the server runs while the app does, and the menu bar icon's popover shows what arrived and sends.
@main
struct FerryMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The popover and the Settings window are AppKit's, made by the delegate; an App needs a scene all the same.
        // Not a Settings scene: that would put a ⌘, item in the app's menu, opening an empty window.
        MenuBarExtra("Ferry", isInserted: .constant(false)) { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MenuModel()
    private var status: StatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()
        Notifications.shared.setUp()
        Notifications.shared.copyItem.withLock { $0 = { [model] id in await model.copy(id: id) } }
        LoginItem.ensureDefault()
        Updates.shared.start()
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
        status = StatusItem(model: model)
        // Tailscale may have changed while the Mac slept; nothing else asks while the popover is closed
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [model] _ in Task { @MainActor in await model.checkPublished() }
        }
        Task {
            await model.start()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "openPopover") {
                try? await Task.sleep(for: .seconds(1))
                status?.show()
            }
            if UserDefaults.standard.bool(forKey: "openSettings") { SettingsWindow.show(model: model) }
            #endif
        }
    }
}
