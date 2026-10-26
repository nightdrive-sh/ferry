import FerryKit
import SwiftUI
import UIKit

enum RowAction {
    case copy, open, openLink, saveToPhotos, saveToFiles, share, remove
}

/// One thing a computer sent: a tile, the text or name, where it came from and when, and its main action.
struct ReceivedRow: View {
    let received: Received
    let isNew: Bool
    let now: Date
    let thumbnail: UIImage?
    /// Its file is on its way to the phone
    var isLoading = false
    let act: (RowAction) -> Void

    @State private var copied = false

    private var item: Item { received.item }
    private var isImage: Bool { item.kind == .file && (item.type ?? "").hasPrefix("image/") }
    private var canSaveToPhotos: Bool {
        item.kind == .file && ((item.type ?? "").hasPrefix("image/") || (item.type ?? "").hasPrefix("video/"))
    }

    /// A one-time code: 4 to 8 digits, alone. Shown large so it can be read at a glance.
    private var isCode: Bool {
        guard item.kind == .text, let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return (4...8).contains(t.count) && t.allSatisfy(\.isNumber)
    }

    var body: some View {
        // Two sibling buttons, not one inside the other: a list row hands each its own taps only so
        HStack(spacing: 13) {
            Button { item.kind == .text ? copy() : act(.open) } label: {
                HStack(spacing: 13) {
                    tile
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        Text(meta).font(.mono(.footnote)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityElement(children: .combine)
            .accessibilityHint(item.kind == .text ? "Copies it" : "Opens it")
            actionButton
        }
        .contextMenu { menu }
    }

    // MARK: Parts

    @ViewBuilder private var tile: some View {
        if isImage, let thumbnail {
            Image(uiImage: thumbnail).resizable().scaledToFill()
                .frame(width: 50, height: 50).clipShape(.rect(cornerRadius: 11))
        } else {
            ZStack {
                if isLoading {
                    ProgressView().tint(Theme.accent)
                        .accessibilityLabel("Loading")
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 50, height: 50)
            .background(Theme.tile, in: .rect(cornerRadius: 11))
        }
    }

    private var symbol: String {
        if item.kind == .file { return isImage ? "photo" : "doc" }
        return item.isLink ? "link" : "text.alignleft"
    }

    @ViewBuilder private var title: some View {
        if copied {
            Text("Copied").font(.mono(.body, weight: .medium)).foregroundStyle(Theme.primary)
        } else if isCode {
            Text(item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                .font(.code).tracking(3).foregroundStyle(Theme.accent)
        } else {
            Text(item.kind == .text ? (item.text ?? "") : (item.name ?? "file"))
                .font(.mono(.body)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if item.kind == .file, let size = item.size { parts.append(ByteSize.format(size)) }
        parts.append(Age.short(now.timeIntervalSince(item.time)))
        parts.append(received.machineName)
        return parts.joined(separator: " · ")
    }

    private var actionButton: some View {
        Button { item.kind == .text ? copy() : act(canSaveToPhotos ? .saveToPhotos : .saveToFiles) } label: {
            Image(systemName: item.kind == .text ? "doc.on.doc" : "arrow.down.to.line")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.tile, in: .circle)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(item.kind == .text ? "Copy" : "Save")
    }

    @ViewBuilder private var menu: some View {
        if item.kind == .text {
            Button("Copy", systemImage: "doc.on.doc") { copy() }
            if item.isLink { Button("Open Link", systemImage: "safari") { act(.openLink) } }
        } else {
            Button("Open", systemImage: "eye") { act(.open) }
            if canSaveToPhotos { Button("Save to Photos", systemImage: "photo.badge.plus") { act(.saveToPhotos) } }
            Button("Save to Files", systemImage: "folder") { act(.saveToFiles) }
        }
        Button("Share", systemImage: "square.and.arrow.up") { act(.share) }
        Button("Remove", systemImage: "trash", role: .destructive) { act(.remove) }
    }

    private func copy() {
        act(.copy)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }
}
