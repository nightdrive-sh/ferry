import FerryServer
import SwiftUI

/// Settings' list of the owner's other devices, where one is forgotten on all of them (docs/protocol.md › Forgetting a
/// device). Forget is final here: only adding the device again brings it back.
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
        } header: {
            Text("Devices")
        } footer: {
            Text("Forget takes a device off the lists on all your devices, and a phone gets no more notifications. A computer comes back when Ferry starts on it again, a phone when you add it again with Add Device.")
                .font(.callout).foregroundStyle(Theme.dim)
        }
    }

    private func row(_ device: Device, @ViewBuilder action: () -> some View) -> some View {
        HStack {
            Image(systemName: Self.symbol(device.kind)).foregroundStyle(Theme.dim).frame(width: 18)
            Text(device.name).font(.mono(.body)).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.middle)
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
