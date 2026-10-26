import AppKit
import os
import SwiftUI

/// Ferry's icon in the menu bar and its popover. An NSStatusItem rather than MenuBarExtra: files can be dropped on the
/// icon, a dot on it says something arrived, and the popover says exactly when it opens and closes.
@MainActor
final class StatusItem: NSObject, NSPopoverDelegate, NSWindowDelegate, NSDraggingDestination {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: MenuModel

    /// `systemImage:` draws the symbol smaller than the menu bar's other icons, so it is made at their size: a
    /// template, so the menu bar tints it for light, dark and highlighted
    static let icon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Ferry")?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /// The icon with a dot at its top right corner, for what arrived and wasn't seen yet: a dot, as on the Mac's own
    /// icons, rather than a count beside it. The tray is cut away around the dot so the two don't run together.
    static let iconWithDot: NSImage = {
        // On the tray's corner, which the symbol draws a little inside its image
        let size = icon.size, radius: CGFloat = 3.5, gap: CGFloat = 1.5
        let center = NSPoint(x: size.width - 4.5, y: size.height - 4)
        let image = NSImage(size: size, flipped: false) { _ in
            icon.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            let around = radius + gap
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: center.x - around, y: center.y - around, width: around * 2, height: around * 2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ferry"
        return image
    }()

    init(model: MenuModel) {
        self.model = model
        super.init()
        if let button = item.button {
            button.image = Self.icon
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggle)
        }
        registerDrops()
        // A new display arrangement can give the status item a new window, which wouldn't take drops
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerDrops() }
        }
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: MenuView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        model.closePopover = { [weak self] in self?.popover.performClose(nil) }
        model.showPopover = { [weak self] in self?.show() }
        follow()
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }

    func show() {
        guard !popover.isShown, let button = item.button else { return }
        // Active first, so the text field can take keys
        NSApp.activate(ignoringOtherApps: true)
        // The system's light or dark, not the menu bar's, which follows the wallpaper
        popover.appearance = NSApp.effectiveAppearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidShow(_ notification: Notification) {
        model.opened()
    }

    func popoverDidClose(_ notification: Notification) {
        model.closed()
    }

    // MARK: Files dropped on the icon

    /// A drag over the icon opens the popover, so it can go on to another device's tile
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !files(sender).isEmpty else { return [] }
        model.iconDragging(true)
        show()
        return .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        model.iconDragging(false)
    }

    /// Dropped on the icon itself: to the device picked, with a checkmark on the icon for a moment
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = files(sender)
        model.iconDragging(false)
        // One send at a time; the popover shows the one under way
        guard !urls.isEmpty, !model.isSending else { return false }
        Task {
            await model.send(.files(urls))
            if case .failed = model.sendState {
                show()   // the reason, with Try Again
            } else {
                flashSent()
            }
        }
        return true
    }

    private func files(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func flashSent() {
        guard let button = item.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let check = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Sent")?.withSymbolConfiguration(config)
        check?.isTemplate = true
        button.image = check
        Task {
            try? await Task.sleep(for: .seconds(2))
            button.image = model.unseen > 0 ? Self.iconWithDot : Self.icon
        }
    }

    /// The button follows the model's count and publish state
    private func follow() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    /// Files dropped on the icon: the button's window takes the drag and hands it to its delegate. Set again whenever the
    /// button changes, in case AppKit has replaced its window.
    private func registerDrops() {
        guard let window = item.button?.window else { return }
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
        #if DEBUG
        Logger(subsystem: "fi.feature.ferry.mac", category: "menu").notice("drop target: true")
        #endif
    }

    private func update() {
        registerDrops()
        guard let button = item.button else { return }
        let unseen = model.unseen
        button.image = unseen > 0 ? Self.iconWithDot : Self.icon
        button.appearsDisabled = model.publish != .published
        button.setAccessibilityLabel(unseen > 0 ? String(localized: "Ferry, \(unseen) new") : "Ferry")
        #if DEBUG
        Logger(subsystem: "fi.feature.ferry.mac", category: "menu").notice("icon: unseen \(unseen) dimmed: \(button.appearsDisabled)")
        #endif
    }
}
