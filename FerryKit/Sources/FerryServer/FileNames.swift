import Foundation
import UniformTypeIdentifiers

/// Names from devices, made safe for Downloads: a phone decides what a file is called, never where it goes.
enum FileNames {
    /// bin/ferry's `safe_name()`: no folders, no control characters, no leading dot (no hidden or dotfiles)
    static func safe(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
            .last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter { $0.value >= 0x20 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let undotted = String(cleaned.drop { $0 == "." })
        return undotted.isEmpty ? "file" : String(undotted.prefix(200))
    }

    /// "name (2).ext", "name (3).ext"… past every name taken, and past an upload still being written there (`.part`)
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        func taken(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) || fm.fileExists(atPath: u.path + ".part") }
        guard taken(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var n = 2
        while true {
            let candidate = dir.appending(path: ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}

enum MIME {
    /// A file's type from its name, as bin/ferry's `mimetypes.guess_type()`; octet-stream when unknown
    static func type(forName name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "application/octet-stream"
            : UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// A clipboard image written out to be sent. Each send gets a folder of its own: the box hard-links what it leaves for
/// a phone, so a file written again in place would change what is still waiting.
public enum ClipboardFile {
    public static func write(_ data: Data, name: String = "Clipboard.png") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Ferry/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try data.write(to: file)
        return file
    }
}
