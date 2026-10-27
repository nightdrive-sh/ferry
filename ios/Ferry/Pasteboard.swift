import FerryKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// What Send Clipboard sends. Reading the pasteboard shows iOS's Paste prompt unless the person allowed Ferry
/// "Paste from Other Apps" in Settings; the checks before it (hasImages, contains(pasteboardTypes:), hasStrings) don't.
@MainActor
enum Pasteboard {
    /// Whether the clipboard holds something Ferry would read, asked without reading it (no Paste prompt). Only a read
    /// makes iOS ask, and only after that does Settings list Paste from Other Apps for Ferry.
    static var hasContent: Bool {
        let pb = UIPasteboard.general
        return hasImage(pb) || pb.hasURLs || pb.hasStrings
    }

    /// An image wins over text when both are there (a screenshot copied with its caption is meant as the picture).
    static func payload() -> SendPayload? {
        let pb = UIPasteboard.general
        if hasImage(pb), let image = image(pb) {
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let file = folder.appending(path: image.name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try image.data.write(to: file)
                return .file(file, name: image.name, type: image.type, clip: true)
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

    /// The image as the app that copied it gave it, not `pb.image` encoded anew: a photo copied in Photos came as a
    /// PNG of over 20 MB where its JPEG was a few. The first of its own types wins, in the order the app put them (a
    /// UIImage says PNG first, so a screenshot stays sharp). A HEIC becomes a JPEG, its metadata kept, since apps on
    /// Linux paste no HEIC from the clipboard.
    private static func image(_ pb: UIPasteboard) -> (data: Data, name: String, type: String)? {
        for type in pb.types {
            switch type {
            case UTType.jpeg.identifier:
                if let data = pb.data(forPasteboardType: type) { return (data, "clipboard.jpg", "image/jpeg") }
            case UTType.png.identifier:
                if let data = pb.data(forPasteboardType: type) { return (data, "clipboard.png", "image/png") }
            case UTType.heic.identifier, UTType.heif.identifier:
                if let data = pb.data(forPasteboardType: type), let jpeg = jpeg(from: data) {
                    return (jpeg, "clipboard.jpg", "image/jpeg")
                }
            default:
                continue
            }
        }
        guard let data = pb.image?.pngData() else { return nil }
        return (data, "clipboard.png", "image/png")
    }

    /// hasImages doesn't count a HEIC on its own (UIPasteboard's image types predate it)
    private static func hasImage(_ pb: UIPasteboard) -> Bool {
        pb.hasImages || pb.contains(pasteboardTypes: [UTType.heic.identifier, UTType.heif.identifier])
    }

    private static func jpeg(from heic: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(heic as CFData, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dest, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
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
