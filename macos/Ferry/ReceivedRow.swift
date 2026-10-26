import AppKit
import FerryKit
import FerryServer
import SwiftUI

enum RowAction {
    case copy, open, openLink, showInFinder, quickLook, remove
    /// Its file is gone from Downloads: the list should drop the row
    case gone
}

/// One thing a device sent: a tile, the text or name, its size, age and sender, and its main action.
struct ReceivedRow: View {
    let item: BoxItem
    let now: Date
    let thumbnail: NSImage?
    let act: (RowAction) -> Void

    @State private var copied = false
    @State private var hovering = false

    private var isFile: Bool { item.kind == "file" }
    private var file: URL? { isFile ? item.path.map { URL(filePath: $0) } : nil }
    private var link: URL? { isFile ? nil : WebLink.url(in: item.text ?? "") }
    private var isImage: Bool { isFile && (item.type ?? "").hasPrefix("image/") }

    /// A one-time code: 4 to 8 digits, alone. Shown large so it can be read at a glance.
    private var code: String? {
        guard !isFile, let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              (4...8).contains(t.count), t.allSatisfy(\.isNumber) else { return nil }
        return t
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: primary) {
                HStack(spacing: 10) {
                    tile
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        Text(meta).font(.mono(.footnote)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(isFile || link != nil ? "Opens it" : "Copies it")
            actionButton
        }
        .padding(.horizontal, 8)
        .frame(height: MenuView.rowHeight)
        .background(hovering ? Theme.tile.opacity(0.7) : .clear, in: .rect(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onDrag(dragged)
        .contextMenu { menu }
    }

    // MARK: Parts

    @ViewBuilder private var tile: some View {
        if isImage, let thumbnail {
            Image(nsImage: thumbnail).resizable().scaledToFill()
                .frame(width: 36, height: 36).clipShape(.rect(cornerRadius: 8))
        } else {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.tile, in: .rect(cornerRadius: 8))
        }
    }

    private var symbol: String {
        if isFile { return isImage ? "photo" : "doc" }
        return link != nil ? "link" : "text.alignleft"
    }

    @ViewBuilder private var title: some View {
        if copied {
            Text("Copied").font(.mono(.body, weight: .medium)).foregroundStyle(Theme.primary)
        } else if let code {
            Text(code).font(.code).tracking(3).foregroundStyle(Theme.accent)
        } else {
            // One line: a text's line breaks show as spaces, and Copy still gives them
            Text(isFile ? (item.name ?? "file") : (item.text ?? "").components(separatedBy: .newlines).joined(separator: " "))
                .font(.mono(.body)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if isFile, let size = item.size { parts.append(ByteSize.format(size)) }
        parts.append(Age.short(now.timeIntervalSince1970 - item.time))
        if let from = item.from, !from.isEmpty { parts.append(from) }
        return parts.joined(separator: " · ")
    }

    private var actionButton: some View {
        Button { isFile ? act(.open) : copy() } label: {
            Image(systemName: isFile ? "arrow.up.forward.app" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.tile, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(isFile ? "Open" : "Copy")
        .accessibilityLabel(isFile ? "Open" : "Copy")
    }

    @ViewBuilder private var menu: some View {
        if isFile {
            Button("Open") { act(.open) }
            Button("Show in Finder") { act(.showInFinder) }
            Button("Quick Look") { act(.quickLook) }
            if let file { ShareLink("Share…", item: file) }
        } else {
            Button("Copy") { copy() }
            if link != nil { Button("Open Link") { act(.openLink) } }
            ShareLink("Share…", item: item.text ?? "")
        }
        Divider()
        Button("Remove", role: .destructive) { act(.remove) }
    }

    // MARK: Actions

    /// A link opens, another text is copied, a file opens in its app
    private func primary() {
        if isFile { act(.open) } else if link != nil { act(.openLink) } else { copy() }
    }

    private func copy() {
        act(.copy)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }

    /// A file drags out into Finder or another app; a text as text
    private func dragged() -> NSItemProvider {
        if let file {
            if FileManager.default.fileExists(atPath: file.path) { return NSItemProvider(contentsOf: file) ?? NSItemProvider() }
            act(.gone)
            return NSItemProvider()   // nothing to drop, not an empty text
        }
        return NSItemProvider(object: (item.text ?? "") as NSString)
    }
}
