import AppKit
import FerryServer

/// What Send Clipboard sends: files copied in Finder as files, an image as a PNG, a text (a link too) as the clipboard.
/// ClipboardPick decides which, so a picture an app puts next to copied text doesn't go in its place.
enum Pasteboard {
    /// nil when nothing on the clipboard can be sent
    static func outgoing(_ pb: NSPasteboard = .general) -> Outgoing? {
        let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let text = pb.string(forType: .string) ?? ""
        let pick = ClipboardPick.choose(types: (pb.types ?? []).map(\.rawValue), hasFiles: !files.isEmpty,
                                        hasImage: NSImage.canInit(with: pb), text: text)
        switch pick {
        case .files:
            return .files(files)
        case .image:
            guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  let file = try? ClipboardFile.write(png) else { return nil }
            return .files([file], clip: true)
        case .text:
            return .text(text, clip: true)
        case .nothing:
            return nil
        }
    }
}

extension NSPasteboard {
    /// nspasteboard.org's mark for a password manager's copy: Maccy, Raycast, Alfred and the like keep no history of it
    static let concealed = PasteboardType("org.nspasteboard.ConcealedType")

    /// A text in place of what was there. Concealed: a code or a password, or what Send Clipboard brought from the
    /// phone (docs/protocol.md › Codes and passwords).
    func put(_ text: String, concealed: Bool) {
        clearContents()
        setString(text, forType: .string)
        if concealed { conceal() }
    }

    /// Marks what was just put here
    func conceal() {
        setData(Data(), forType: Self.concealed)
    }
}
