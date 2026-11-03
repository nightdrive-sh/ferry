import FerryServer
import SwiftUI

/// While files are dragged over the popover: a tile per device, and dropping on one sends there without changing the
/// device picked. The tiles only draw: one drop area over them all takes the drag (TileDropArea).
struct DropTiles: View {
    @Bindable var model: MenuModel
    /// Which tile the drag is over
    @Binding var targeted: String?
    /// The drag is over the tiles, so the popover keeps showing them while the area has it
    @Binding var inside: Bool
    let height: CGFloat

    @State private var frames: [String: CGRect] = [:]
    private nonisolated static let space = "dropTiles"

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
            .coordinateSpace(.named(Self.space))
            .overlay {
                TileDropArea(frames: frames, open: { id in devices.first { $0.id == id }.map(open) ?? false },
                             targeted: $targeted, inside: $inside) { id, dropped in
                    guard let device = devices.first(where: { $0.id == id }) else { return }
                    Task {
                        let urls = await dropped.files()
                        if !urls.isEmpty { await model.send(.files(urls), to: device) }
                    }
                }
            }
        }
    }

    /// A computer has to answer now; a phone takes what waits in the box when it wakes
    private func open(_ device: Device) -> Bool {
        (device.kind != .computer || device.online) && !model.isSending
    }

    private func tile(_ device: Device) -> some View {
        VStack(spacing: 8) {
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
        .opacity(open(device) ? 1 : 0.4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop here to send to \(device.name)")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[device.id] = $0 }
    }

    private func symbol(_ kind: Device.Kind) -> String {
        switch kind {
        case .computer: "desktopcomputer"
        case .phone: "iphone"
        case .tablet: "ipad"
        }
    }
}
