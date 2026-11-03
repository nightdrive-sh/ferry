import FerryKit
import FerryServer
import SwiftUI

/// A send to a computer that is asleep or off, waiting on this Mac until it is back (docs/protocol.md › Clients ›
/// Sends that wait): what it is, whom it waits for and how long it has, and Cancel.
struct WaitingRow: View {
    let send: WaitingSend
    let now: Date
    let cancel: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.tile, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(send.what).font(.mono(.body)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                Text(meta).font(.mono(.footnote)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Theme.tile, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 8)
        .frame(height: MenuView.rowHeight)
        .background(hovering ? Theme.tile.opacity(0.7) : .clear, in: .rect(cornerRadius: 10))
        .onHover { hovering = $0 }
        .contextMenu { Button("Cancel Send", role: .destructive, action: cancel) }
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        var parts: [String] = []
        if send.kind == "file" { parts.append(ByteSize.format(send.size)) }
        parts.append(String(localized: "Waiting for \(send.name)"))
        parts.append(Age.left(send.until - now.timeIntervalSince1970))
        return parts.joined(separator: " · ")
    }
}
