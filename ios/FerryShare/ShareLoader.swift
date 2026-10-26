import FerryKit
import UIKit
import UniformTypeIdentifiers

/// What the sharing app put in the share sheet, as `Shared`. Files are taken as files, never as `Data`: a share
/// extension gets about 120 MB of memory, and a video can be gigabytes.
enum ShareLoader {
    static func load(_ items: [NSExtensionItem]) async -> [Shared] {
        var shared: [Shared] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if let s = await load(provider) { shared.append(s) }
        }
        return shared
    }

    private static func load(_ p: NSItemProvider) async -> Shared? {
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL else { return nil }
            return url.isFileURL ? .file(url) : .link(url)
        }
        // A photo, a video, a document: the first type that is a file's contents rather than text (rich text from
        // Notes or Mail is `public.text` too, and goes as the plain text beside it)
        if let type = p.registeredContentTypes.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .text) }) {
            if let file = await fileCopy(p, type) { return .file(file) }
            if type.conforms(to: .image), let png = await imageAsPNG(p) { return .file(png) }
            return nil
        }
        if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            return .text(text)
        }
        // A text file shared from Files: its contents as a file, under its name
        if let type = p.registeredContentTypes.first(where: { $0.conforms(to: .data) }), let file = await fileCopy(p, type) {
            return .file(file)
        }
        return nil
    }

    /// The provider's file is removed when its callback returns: a copy, in a temp folder of its own, outlives it.
    private static func fileCopy(_ p: NSItemProvider, _ type: UTType) async -> URL? {
        await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url else { return c.resume(returning: nil) }
                c.resume(returning: try? copy(url, named: url.lastPathComponent))
            }
        }
    }

    /// An image some apps (Markup, screenshots) hand over only as a picture, not a file.
    private static func imageAsPNG(_ p: NSItemProvider) async -> URL? {
        guard let image = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier) as? UIImage,
              let data = image.pngData() else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = folder.appending(path: "image.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }

    private static func copy(_ file: URL, named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: name)
        try FileManager.default.copyItem(at: file, to: dest)
        return dest
    }
}
