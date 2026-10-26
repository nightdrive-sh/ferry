import FerryKit
import UIKit
import UniformTypeIdentifiers

/// What Send Clipboard sends. Reading the pasteboard shows iOS's Paste prompt unless the person allowed Ferry
/// "Paste from Other Apps" in Settings; the checks before it (hasImages, hasStrings) don't.
@MainActor
enum Pasteboard {
    /// Whether the clipboard holds something Ferry would read, asked without reading it (no Paste prompt). Only a read
    /// makes iOS ask, and only after that does Settings list Paste from Other Apps for Ferry.
    static var hasContent: Bool {
        let pb = UIPasteboard.general
        return pb.hasImages || pb.hasURLs || pb.hasStrings
    }

    /// An image wins over text when both are there (a screenshot copied with its caption is meant as the picture).
    static func payload() -> SendPayload? {
        let pb = UIPasteboard.general
        if pb.hasImages, let image = pb.image, let data = image.pngData() {
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let file = folder.appending(path: "clipboard.png")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file)
                return .file(file, name: "clipboard.png", type: "image/png", clip: true)
            } catch {
                return nil
            }
        }
        if pb.hasURLs, let url = pb.url { return .text(url.absoluteString, clip: true) }
        if pb.hasStrings, let s = pb.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(s, clip: true)
        }
        return nil
    }

    /// A text copied from Received or a notification. A code or a password stays on this phone: Universal Clipboard
    /// would hand it to a Mac, whose clipboard history keeps it (docs/protocol.md › Codes and passwords).
    static func copy(_ text: String) {
        guard Secret.looksLike(text) else {
            UIPasteboard.general.string = text
            return
        }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
    }
}
