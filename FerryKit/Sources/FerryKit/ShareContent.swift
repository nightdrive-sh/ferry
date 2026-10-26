import Foundation
import UniformTypeIdentifiers

/// One thing an app put in the share sheet, as the share extension found it.
public enum Shared: Sendable, Equatable {
    /// A file on disk: a photo, a video, a document, or an image written out as PNG.
    case file(URL)
    case link(URL)
    case text(String)
}

/// What a share becomes.
public enum ShareContent {
    /// Texts and links go as texts that wait for Copy; files are copied into `folder`, each in a folder of its own so
    /// two with the same name both arrive, and file to file, never through memory (a video can be gigabytes, and a
    /// share extension gets about 120 MB). A file that can't be copied (an iCloud placeholder, a full disk) is left
    /// out, not the whole share.
    public static func payloads(_ shared: [Shared], copyingInto folder: URL) -> [SendPayload] {
        var files: [URL] = [], links: [URL] = [], texts: [String] = []
        for s in shared {
            switch s {
            case .file(let url): files.append(url)
            case .link(let url): if url.isFileURL { files.append(url) } else { links.append(url) }
            case .text(let t): if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { texts.append(t) }
            }
        }
        // Safari shares the page's title beside its address: the address is what was meant
        if !links.isEmpty { texts = [] }
        var payloads = links.map { SendPayload.text($0.absoluteString, clip: false) } + texts.map { .text($0, clip: false) }
        for file in files {
            // A file from Files is outside the extension's sandbox until accessed
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let dir = folder.appending(path: UUID().uuidString)
            let copy = dir.appending(path: file.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: copy)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            let type = UTType(filenameExtension: copy.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            payloads.append(.file(copy, name: copy.lastPathComponent, type: type, clip: false))
        }
        return payloads
    }

    /// The line at the top of the share view: the file's name or the text's first line, or how many there are.
    public static func summary(_ payloads: [SendPayload]) -> String {
        if payloads.count == 1 {
            switch payloads[0] {
            case .file(_, let name, _, _): return name
            case .text(let t, _):
                let line = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
                return String(line.prefix(80))
            }
        }
        let types = payloads.map { p -> String in if case .file(_, _, let type, _) = p { type } else { "" } }
        if types.allSatisfy({ $0.hasPrefix("image/") }) { return "\(payloads.count) photos" }
        if types.allSatisfy({ $0.hasPrefix("video/") }) { return "\(payloads.count) videos" }
        return "\(payloads.count) items"
    }
}
