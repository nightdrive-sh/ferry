import AppKit
import FerryServer
import ServiceManagement
import SwiftUI

/// Ferry's small Settings window, opened from the popover's ⋯ menu: one window, made once.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: MenuModel) {
        model.closePopover()
        // Closing the popover stopped its refresh: what Settings shows is asked for now
        Task { await model.refresh() }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = String(localized: "Ferry Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // A menu bar app isn't in front by itself
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Open at Login is on by default: set once, on the first launch, and after that its user's choice.
enum LoginItem {
    static func ensureDefault() {
        #if !DEBUG
        // A debug build in DerivedData must not become what opens at login
        guard !UserDefaults.standard.bool(forKey: "loginItemChosen") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemChosen")
        try? SMAppService.mainApp.register()
        #endif
    }
}

struct SettingsView: View {
    @Bindable var model: MenuModel

    @State private var login = SMAppService.mainApp.status
    @State private var copied = false
    @State private var checksForUpdates = Updates.shared.checksAutomatically

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(short) (\(build))")
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { login == .enabled }, set: setLogin))
                    .accessibilityLabel("Open at Login")
                // What a user who turned Ferry off in System Settings sees: only System Settings can turn it on again
                if login == .requiresApproval {
                    HStack {
                        Text("Turned off in System Settings › General › Login Items & Extensions.")
                            .font(.callout).foregroundStyle(Theme.dim)
                        Spacer()
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Section("Address") {
                HStack {
                    Text(model.address?.absoluteString ?? String(localized: "None yet: Tailscale is off"))
                        .font(.mono(.footnote)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let address = model.address {
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address.absoluteString, forType: .string)
                            copied = true
                        }
                    }
                }
            }
            DevicesSection(model: model)
            Section("Publishing") {
                HStack {
                    Text(publishing)
                    Spacer()
                    if model.publish == .stopped {
                        Button("Publish") { Task { await model.publish(true) } }
                    } else {
                        Button("Stop Publishing") { Task { await model.publish(false) } }
                            .disabled(model.publish != .published)
                    }
                }
                Text("Quitting Ferry leaves it published: your devices show this Mac as unreachable until Ferry runs again.")
                    .font(.callout).foregroundStyle(Theme.dim)
            }
            Section("Updates") {
                Toggle("Check for Updates Automatically", isOn: $checksForUpdates)
                    .onChange(of: checksForUpdates) { Updates.shared.checksAutomatically = checksForUpdates }
                HStack {
                    Text(version).font(.mono(.footnote))
                    Spacer()
                    Button("Check Now") { Updates.shared.checkForUpdates() }
                }
            }
            Section("About") {
                Text("Ferry trusts everyone who can use this Mac. Use it on a Mac that is yours alone.")
                    .font(.callout).foregroundStyle(Theme.dim)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        // The window is made once and kept, and Login Items can be changed in System Settings meanwhile: asked again
        // whenever it comes to the front
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            login = SMAppService.mainApp.status
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var publishing: String {
        switch model.publish {
        case .published: String(localized: "On your tailnet")
        case .stopped: String(localized: "Off on this Mac")
        default: String(localized: "Not on your tailnet")
        }
    }

    private func setLogin(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        login = SMAppService.mainApp.status
        // Turned off in System Settings, Ferry can't turn itself on again: System Settings is opened where it can be
        if on && login == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
