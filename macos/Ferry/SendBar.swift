import AppKit
import FerryServer
import SwiftUI

/// The bottom of the popover: the device sends go to, and Aa, Send Clipboard and + under it.
struct SendBar: View {
    @Bindable var model: MenuModel

    @State private var composing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            if case .failed(let reason) = model.sendState {
                Text(reason)
                    .font(.callout).foregroundStyle(Theme.away)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .frame(maxWidth: .infinity)
            }
            pill
            if composing { compose } else { buttons }
        }
    }

    // MARK: The device

    private var pill: some View {
        Menu {
            ForEach(model.devices) { device in
                // A toggle is how a Mac menu shows its checkmark
                Toggle(device.name, isOn: Binding(get: { device.id == model.target?.id },
                                                  set: { _ in Task { await model.pick(device) } }))
                // A phone takes what waits in the box when it wakes; a computer has to answer now
                .disabled(device.kind == .computer && !device.online)
            }
            if !model.devices.isEmpty { Divider() }
            Button("Add Device…") { model.page = .addDevice }
        } label: {
            HStack(spacing: 7) {
                if let target = model.target {
                    Circle().fill(target.online ? Theme.online : Theme.away).frame(width: 8, height: 8)
                    Text(target.name).font(.mono(.subheadline, weight: .medium)).foregroundStyle(Theme.text)
                } else {
                    Text("No devices yet").font(.mono(.subheadline, weight: .medium)).foregroundStyle(Theme.dim)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isSending)
        .accessibilityLabel(model.target.map { String(localized: "Send to \($0.name), change device") }
            ?? String(localized: "Add a device"))
    }

    // MARK: The buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { start() } label: {
                Image(systemName: "textformat").frame(width: 20, height: 20)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .help("Type a text")
            .accessibilityLabel("Type a text")
            .disabled(model.isSending)

            sendClipboard

            Button { pickFiles() } label: {
                Image(systemName: "plus").frame(width: 20, height: 20)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .help("Send files")
            .disabled(model.isSending)
            .accessibilityLabel("Send files")
        }
        .controlSize(.large)
    }

    private var sendClipboard: some View {
        Button {
            Task { await model.sendClipboard() }
        } label: {
            HStack(spacing: 6) {
                if let clipboardSymbol { Image(systemName: clipboardSymbol) }
                Text(clipboardTitle)
            }
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                // How far an upload to another computer has got, in the button's own text colour
                .overlay(alignment: .bottom) {
                    if case .sending(let fraction?) = model.sendState {
                        GeometryReader { g in
                            Capsule().fill(.foreground.opacity(0.8))
                                .frame(width: max(4, g.size.width * fraction), height: 3)
                        }
                        .frame(height: 3)
                        .offset(y: 6)
                        .allowsHitTesting(false)
                    }
                }
        }
        // The system's white on violet: dark text on it reads as a disabled button on a Mac
        .buttonStyle(.glassProminent)
        .tint(Theme.primary)
        .disabled(model.isSending)
    }

    private var clipboardTitle: String {
        switch model.sendState {
        case .idle: String(localized: "Send Clipboard")
        case .sending: String(localized: "Sending…")
        case .sent(let name): String(localized: "Sent to \(name) ✓")
        case .failed: String(localized: "Try Again")
        case .nothing: String(localized: "Nothing on the clipboard")
        }
    }

    /// None after a send: its title ends in ✓ already
    private var clipboardSymbol: String? {
        switch model.sendState {
        case .failed: "arrow.clockwise"
        case .sent: nil
        default: "doc.on.clipboard"
        }
    }

    // MARK: Aa

    private var compose: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Type a text", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .font(.mono(.body))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                // Return sends, Shift-Return starts a new line, Escape gives up
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        text += "\n"
                    } else {
                        sendText()
                    }
                    return .handled
                }
                .onExitCommand { composing = false }
            Button("Cancel") { composing = false }
            Button("Send") { sendText() }
                .buttonStyle(.glassProminent).tint(Theme.primary)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func start() {
        text = ""
        composing = true
        focused = true
    }

    private func sendText() {
        let typed = text
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composing = false
        Task { await model.send(.text(typed, clip: false)) }
    }

    // MARK: +

    /// The system's open panel, with the popover out of its way; the files go to the device picked now
    private func pickFiles() {
        model.closePopover()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = String(localized: "Send")
        let device = model.target
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            // Back in the popover, where the progress and the result show
            model.showPopover()
            Task { await model.send(.files(urls), to: device) }
        }
    }
}
