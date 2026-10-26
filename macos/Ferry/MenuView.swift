import AppKit
import FerryKit
import FerryServer
import QuickLook
import SwiftUI

/// The popover: Received, then the device and the bar that sends to it.
struct MenuView: View {
    @Bindable var model: MenuModel

    static let width: CGFloat = 360
    static let rowHeight: CGFloat = 50
    static let listHeight: CGFloat = 420

    @State private var confirmingClear = false
    @State private var preview: URL?
    /// The drag is over the popover, or over one of its device tiles
    @State private var overPopover = false
    @State private var overTile: String?

    private var dragging: Bool {
        model.draggingOverIcon || overPopover || overTile != nil || showTiles
    }

    #if DEBUG
    private let showTiles = UserDefaults.standard.bool(forKey: "showDropTiles")
    #else
    private let showTiles = false
    #endif

    /// The list's height, which the tiles keep so the popover doesn't jump while a drag comes and goes
    private var listHeight: CGFloat {
        min(CGFloat(model.received.count) * (Self.rowHeight + 2), Self.listHeight)
    }

    var body: some View {
        VStack(spacing: 8) {
            if model.page == .addDevice {
                addDevice
            } else {
                main
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .quickLookPreview($preview)
        // Only to know a drag is over the popover: the tiles take the drop
        .dropDestination(for: URL.self) { _, _ in false } isTargeted: { overPopover = $0 }
    }

    @ViewBuilder private var main: some View {
            header
            if SetupStep.needed(model) {
                SetupStep(model: model)
            } else if dragging {
                DropTiles(model: model, targeted: $overTile, height: max(listHeight, 200))
            } else {
                NotificationsLine(model: model)
                received
            }
            // Under a step too, disabled, so the popover doesn't jump in size when the step clears
            SendBar(model: model)
                .padding(.top, 6)
                .disabled(SetupStep.needed(model))
    }

    @ViewBuilder private var addDevice: some View {
        HStack {
            Button {
                model.page = .main
            } label: {
                Label("Received", systemImage: "chevron.left")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            Spacer()
            Text("ADD DEVICE").font(.mono(.caption, weight: .bold)).tracking(1.5).foregroundStyle(Theme.primary)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        AddDeviceView(model: model)
    }

    private var more: some View {
        Menu {
            Button("Add Device…") { model.page = .addDevice }
            Button("Settings…") { SettingsWindow.show(model: model) }
                .keyboardShortcut(",")
            Button("Check for Updates…") {
                model.closePopover()
                Updates.shared.checkForUpdates()
            }
            Divider()
            Button("Quit Ferry") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.dim)
        .accessibilityLabel("More")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(SetupStep.needed(model) ? "FERRY" : dragging ? "DROP TO SEND" : "RECEIVED")
                .font(.mono(.caption, weight: .bold)).tracking(1.5)
                .foregroundStyle(Theme.primary)
            Spacer()
            if dragging || SetupStep.needed(model) {
                EmptyView()
            } else if confirmingClear {
                Text("Clear ^[\(model.received.count) item](inflect: true)?").font(.callout).foregroundStyle(Theme.text)
                    .lineLimit(1).fixedSize()
                Button("Cancel") { confirmingClear = false }
                Button("Clear", role: .destructive) {
                    confirmingClear = false
                    Task { await model.clear() }
                }
            } else if !model.received.isEmpty {
                Button("Clear") { confirmingClear = true }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
            // The question needs the row's width; the menu is back once it is answered
            if !confirmingClear { more }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 24)
        // A question left unanswered goes away by itself
        .task(id: confirmingClear) {
            guard confirmingClear else { return }
            try? await Task.sleep(for: .seconds(5))
            confirmingClear = false
        }
    }

    // MARK: Received

    @ViewBuilder private var received: some View {
        if model.received.isEmpty {
            VStack(spacing: 4) {
                Text("Things your devices send appear here.")
                Text("On your iPhone, Send Clipboard sends what you copied to this Mac.")
            }
            .font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            TimelineView(.everyMinute) { context in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.received, id: \.id) { item in
                            ReceivedRow(item: item, now: context.date, thumbnail: model.thumbnail(for: item)) { action in
                                act(action, on: item)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // The list grows with its rows, up to a height, and then scrolls
                .frame(height: listHeight)
            }
        }
    }

    private func act(_ action: RowAction, on item: BoxItem) {
        switch action {
        case .copy:
            model.copy(item)
        case .openLink:
            if let url = WebLink.url(in: item.text ?? "") { NSWorkspace.shared.open(url) }
        case .open:
            if let file = model.file(of: item) { NSWorkspace.shared.open(file) }
        case .showInFinder:
            if let file = model.file(of: item) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        case .quickLook:
            preview = model.file(of: item)
        case .remove:
            Task { await model.remove(item) }
        case .gone:
            Task { await model.refresh() }
        }
    }
}
