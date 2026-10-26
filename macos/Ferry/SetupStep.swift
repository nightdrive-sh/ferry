import AppKit
import FerryServer
import SwiftUI
import UserNotifications

/// One plain step in place of the list, while something stands between Ferry and the tailnet.
struct SetupStep: View {
    @Bindable var model: MenuModel

    /// Whether the popover shows a step rather than Received
    static func needed(_ model: MenuModel) -> Bool {
        model.startError != nil || model.publish != .published
    }

    var body: some View {
        VStack(spacing: 10) {
            if let step {
                Image(systemName: step.symbol)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Theme.accent)
                Text(step.title).font(.headline).foregroundStyle(Theme.text)
                if let text = step.text {
                    Text(text).font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    ForEach(step.buttons, id: \.title) { button in
                        Button(button.title) { button.action() }
                        .buttonStyle(.glassProminent).tint(Theme.primary)
                    }
                }
                .padding(.top, 4)
                if step.working { ProgressView().controlSize(.small) }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private struct Step {
        var symbol: String
        var title: String
        var text: String?
        var buttons: [(title: String, action: () -> Void)] = []
        var working = false
    }

    private var step: Step? {
        if let error = model.startError {
            return Step(symbol: "exclamationmark.triangle", title: String(localized: "Ferry couldn't start"), text: error,
                        buttons: [(String(localized: "Try Again"), { Task { await model.start() } })])
        }
        switch model.publish {
        case nil, .published:
            return nil
        case .tailscaleMissing:
            return Step(symbol: "arrow.down.circle", title: String(localized: "Install Tailscale"),
                        text: String(localized: "Ferry sends between your devices over Tailscale."),
                        buttons: [(String(localized: "Get Tailscale"), { open("https://tailscale.com/download") })])
        case .tailscaleOff:
            // Homebrew's tailscaled has no app to open: it is logged in from Terminal
            guard let app = tailscaleApp else {
                return Step(symbol: "network.slash", title: String(localized: "Log In to Tailscale"),
                            text: String(localized: "Run tailscale up in Terminal and log in, with the same account as your other devices."))
            }
            return Step(symbol: "network.slash", title: String(localized: "Open Tailscale"),
                        text: String(localized: "Open Tailscale and log in, with the same account as your other devices."),
                        buttons: [(String(localized: "Open Tailscale"), {
                            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                        })])
        case .notPublished:
            return Step(symbol: "network", title: String(localized: "Putting Ferry on your tailnet…"), working: true)
        case .problem(let message, let link):
            var buttons: [(title: String, action: () -> Void)] = []
            if let link { buttons.append((String(localized: "Open in Browser"), { NSWorkspace.shared.open(link) })) }
            buttons.append((String(localized: "Try Again"), { Task { await model.publish(true) } }))
            return Step(symbol: "exclamationmark.triangle", title: String(localized: "Tailscale said no"), text: message,
                        buttons: buttons)
        case .stopped:
            return Step(symbol: "pause.circle", title: String(localized: "Ferry is off on this Mac"),
                        text: String(localized: "Your devices can't reach it until you publish it again."),
                        buttons: [(String(localized: "Publish"), { Task { await model.publish(true) } })])
        }
    }

    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    /// The standalone Tailscale or the App Store one, whichever this Mac has; none with only the open-source tailscaled
    private var tailscaleApp: URL? {
        let known = URL(filePath: "/Applications/Tailscale.app")
        return ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            ?? (FileManager.default.fileExists(atPath: known.path) ? known : nil)
    }
}

/// A line above the list while macOS doesn't let Ferry notify: nothing would tell its user when something arrives.
struct NotificationsLine: View {
    @Bindable var model: MenuModel

    var body: some View {
        switch model.notifications {
        case .denied:
            line(String(localized: "Notifications are off, so nothing tells you when something arrives."),
                 button: String(localized: "Turn On…")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=fi.feature.ferry.mac") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .notDetermined:
            line(String(localized: "Ferry can tell you when something arrives."), button: String(localized: "Allow")) {
                Task { await model.allowNotifications() }
            }
        default:
            EmptyView()
        }
    }

    private func line(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bell.slash").foregroundStyle(Theme.dim)
            Text(text).font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(button, action: action).controlSize(.small)
        }
        .padding(.horizontal, 8)
    }
}
