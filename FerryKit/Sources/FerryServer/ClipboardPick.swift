import Foundation

/// Which of the clipboard's representations Send Clipboard sends. Apps such as Numbers and Word put a picture of the
/// copied text next to the text, so an image wins only when the clipboard leads with one (a screenshot, Copy Image).
public enum ClipboardPick {
    public enum Kind: Equatable, Sendable { case files, image, text, nothing }

    static let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "public.heic"]

    /// types: the pasteboard's type identifiers, in its order; text: its plain text, "" when it has none
    public static func choose(types: [String], hasFiles: Bool, hasImage: Bool, text: String) -> Kind {
        // An image copied in Notes, Mail or TextEdit comes with a plain text of only its attachment mark (U+FFFC):
        // that isn't text to send
        let hasText = text.contains { !$0.isWhitespace && $0 != "\u{FFFC}" }
        if hasFiles { return .files }
        if hasImage, let first = types.first, imageTypes.contains(first) { return .image }
        if hasText { return .text }
        return hasImage ? .image : .nothing
    }
}
