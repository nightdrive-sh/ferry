import FerryKit
import SwiftUI

/// A send to a computer that is asleep or off, waiting on the phone until it is back (docs/protocol.md › Clients ›
/// Sends that wait): what it is, whom it waits for and how long it has, and Cancel.
struct WaitingRow: View {
    let send: QueuedSend
    let now: Date
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "clock")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 50, height: 50)
                .background(Theme.tile, in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(send.what).font(.mono(.body)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                Text(meta).font(.mono(.footnote)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.tile, in: .circle)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel")
        }
        .contextMenu { Button("Cancel Send", systemImage: "xmark", role: .destructive, action: cancel) }
    }

    private var meta: String {
        var parts: [String] = []
        if send.kind == .file, let size = send.size { parts.append(ByteSize.format(size)) }
        parts.append(String(localized: "Waiting for \(send.machineName)"))
        parts.append(Age.left(send.until.timeIntervalSince(now)))
        return parts.joined(separator: " · ")
    }
}
