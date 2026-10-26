import SwiftUI
import UIKit

/// How to send without iOS's Paste prompt. Shown once after the first Send Clipboard, and from settings.
struct PasteHelpView: View {
    var done: (() -> Void)?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 34)).foregroundStyle(Theme.primary)
            Text("Send without the Paste prompt").font(.title2.bold()).foregroundStyle(Theme.accent)
            Text("iOS asks every time an app reads what another app copied. Allow Ferry once, and Send Clipboard sends with one tap:")
                .foregroundStyle(Theme.text)
            Text("Settings › Apps › Ferry › Paste from Other Apps › Allow")
                .font(.mono(.callout, weight: .medium)).foregroundStyle(Theme.accent)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: .rect(cornerRadius: 12))
            Text("The setting is in your iPhone's language, and it shows once Ferry has asked to paste.")
                .font(.footnote).foregroundStyle(Theme.dim)
            Spacer()
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("Open Settings").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 54)
                    .foregroundStyle(Theme.onPrimary).background(Theme.primary, in: .capsule)
            }
            .buttonStyle(.plain)
            if let done {
                Button("Not Now", action: done).frame(maxWidth: .infinity).foregroundStyle(Theme.dim)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}
