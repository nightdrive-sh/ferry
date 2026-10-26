import FerryServer
import SwiftUI

/// While files are dragged over the popover: a tile per device, and dropping on one sends there without changing the
/// device picked.
struct DropTiles: View {
    @Bindable var model: MenuModel
    /// Which tile the drag is over, so the popover keeps showing the tiles while a nested target has it
    @Binding var targeted: String?
    let height: CGFloat

    private var devices: [Device] {
        // Online first; the order within each stays the device list's
        model.devices.filter(\.online) + model.devices.filter { !$0.online }
    }

    var body: some View {
        if devices.isEmpty {
            Text("No devices to send to yet: add one with Add Device.")
                .font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: height)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(devices) { device in tile(device) }
                }
                .padding(2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: height)
        }
    }

    private func tile(_ device: Device) -> some View {
        // A computer has to answer now; a phone takes what waits in the box when it wakes
        let open = (device.kind != .computer || device.online) && !model.isSending
        return VStack(spacing: 8) {
            Image(systemName: symbol(device.kind))
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.accent)
            Text(device.name).font(.mono(.subheadline, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(Theme.tile, in: .rect(cornerRadius: 12))
        .overlay {
            if targeted == device.id { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.primary, lineWidth: 2) }
        }
        .opacity(open ? 1 : 0.4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop here to send to \(device.name)")
        .dropDestination(for: URL.self) { urls, _ in
            guard open, !urls.isEmpty else { return false }
            targeted = nil
            Task { await model.send(.files(urls), to: device) }
            return true
        } isTargeted: { over in
            if over, open { targeted = device.id } else if targeted == device.id { targeted = nil }
        }
    }

    private func symbol(_ kind: Device.Kind) -> String {
        switch kind {
        case .computer: "desktopcomputer"
        case .phone: "iphone"
        case .tablet: "ipad"
        }
    }
}
