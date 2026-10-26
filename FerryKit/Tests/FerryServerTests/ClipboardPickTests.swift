import Testing
@testable import FerryServer

@Suite struct ClipboardPickTests {
    @Test func clipboardPick() {
        #expect(ClipboardPick.choose(types: ["public.file-url", "public.utf8-plain-text"], hasFiles: true, hasImage: false, text: "a") == .files)
        // A screenshot
        #expect(ClipboardPick.choose(types: ["public.png"], hasFiles: false, hasImage: true, text: "") == .image)
        // Numbers, Word: the text, with a picture of it alongside
        #expect(ClipboardPick.choose(types: ["public.utf8-plain-text", "public.rtf", "public.tiff"], hasFiles: false, hasImage: true,
                                     text: "Totals") == .text)
        // Copy Image in a browser
        #expect(ClipboardPick.choose(types: ["public.tiff", "public.html"], hasFiles: false, hasImage: true, text: "https://x.y/a.png") == .image)
        #expect(ClipboardPick.choose(types: ["com.example.private"], hasFiles: false, hasImage: false, text: "") == .nothing)
    }

    @Test func attachmentTextDoesNotHideTheImage() {   // Final review: an image copied in Notes or Mail sent "\u{FFFC}"
        #expect(ClipboardPick.choose(types: ["com.apple.flat-rtfd", "public.utf8-plain-text", "public.tiff"], hasFiles: false,
                                     hasImage: true, text: "\u{FFFC}") == .image)
        #expect(ClipboardPick.choose(types: ["public.rtf", "public.utf8-plain-text", "public.png"], hasFiles: false,
                                     hasImage: true, text: " \r\n") == .image)
        #expect(ClipboardPick.choose(types: ["public.utf8-plain-text"], hasFiles: false, hasImage: false, text: "\u{FFFC}") == .nothing)
    }
}
