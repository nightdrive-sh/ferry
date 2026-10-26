import FerryServer
import SwiftUI

/// Settings' list of the owner's other devices, where one is forgotten on all of them (docs/protocol.md › Forgetting a
/// device) or brought back.
struct DevicesSection: View {
    @Bindable var model: MenuModel

    var body: some View {
        Section {
            if model.devices.isEmpty {
                Text("No other device yet: add one with Add Device.").foregroundStyle(Theme.dim)
            }
            ForEach(model.devices) { device in
                row(device) {
                    Button("Forget") { Task { await model.forget(device) } }
                        .accessibilityLabel("Forget \(device.name)")
                }
            }
            ForEach(model.forgotten) { device in
                row(device, forgotten: true) {
                    Button("Bring Back") { Task { await model.unforget(device) } }
                        .accessibilityLabel("Bring back \(device.name)")
                }
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Forget takes a device off the lists on all your devices, and a phone gets no more notifications. It stays forgotten until you bring it back.")
                .font(.callout).foregroundStyle(Theme.dim)
        }
    }

    private func row(_ device: Device, forgotten: Bool = false, @ViewBuilder action: () -> some View) -> some View {
        HStack {
            Image(systemName: Self.symbol(device.kind)).foregroundStyle(Theme.dim).frame(width: 18)
            Text(device.name).font(.mono(.body)).foregroundStyle(forgotten ? Theme.dim : Theme.text)
                .lineLimit(1).truncationMode(.middle)
            if forgotten { Text("Forgotten").font(.callout).foregroundStyle(Theme.dim) }
            Spacer()
            action()
        }
    }

    static func symbol(_ kind: Device.Kind) -> String {
        switch kind {
        case .computer: "desktopcomputer"
        case .phone: "iphone"
        case .tablet: "ipad"
        }
    }
}
