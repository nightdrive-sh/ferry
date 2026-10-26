import CryptoKit
import Foundation

/// The files the computers sent, kept on the phone while their items are in the boxes: a thumbnail, Open, Share and
/// Save don't wait for the computer again, and work while it sleeps. The app puts it in Caches, so iOS may empty it
/// when space runs out; a file is then fetched again.
public struct FileCache: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// One folder per item, named from its Received.id (machine and item id), holding the file under its own name so
    /// a share sheet shows that name.
    static func folder(for id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func folderURL(_ id: String) -> URL { directory.appending(path: Self.folder(for: id)) }

    public func file(for r: Received) -> URL? {
        let folder = folderURL(r.id)
        guard let name = try? FileManager.default.contentsOfDirectory(atPath: folder.path()).first else { return nil }
        return folder.appending(path: name)
    }

    /// Moves a downloaded file in (from HTTPBackend's folder of its own, which goes) and returns where it is now.
    public func store(_ downloaded: URL, for r: Received) throws -> URL {
        let folder = folderURL(r.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: downloaded.lastPathComponent)
        try FileManager.default.moveItem(at: downloaded, to: dest)
        try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent())
        return dest
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folderURL(id))
    }

    /// Everything that no longer belongs to an item still in a box goes.
    public func prune(keeping ids: Set<String>) {
        let keep = Set(ids.map(Self.folder(for:)))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? [] where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}
