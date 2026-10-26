import AppKit
import CoreImage.CIFilterBuiltins
import FerryKit
import SwiftUI

/// The Mac's address as a QR code: the link to nightdrive.sh's add page, which the iPhone app opens (the Camera) or reads
/// (its own scanner). The address itself shows under it, for typing.
struct AddDeviceView: View {
    @Bindable var model: MenuModel

    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            if let address = model.address, let qr = Self.qrCode(SetupAddress.link(for: address).absoluteString) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(12)
                    // Black on white in light and dark alike: that is what a camera reads
                    .background(Color(nsColor: .white), in: .rect(cornerRadius: 12))
                    .accessibilityLabel("QR code of this Mac's address")
                HStack(spacing: 8) {
                    Text(address.absoluteString)
                        .font(.mono(.footnote)).foregroundStyle(Theme.text)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address.absoluteString, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
                Text("Scan this with your iPhone's Camera, or in the Ferry app (Add a Computer). Ferry for iPhone is on the App Store as Ferry: Device Mailbox.")
                    .font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This Mac has no address on your tailnet yet. Open Tailscale and log in, with the same account as your other devices.")
                    .font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                    .frame(minHeight: 200)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Core Image's generator, so no dependency; scaled up whole modules, never smoothed
    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
