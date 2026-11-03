import AppKit
import FerryServer
import UniformTypeIdentifiers

/// What a drag onto Ferry brings, as files to send. Finder gives file URLs; Photos (and Safari's images, Mail's
/// attachments) give file promises instead, which the source writes into a folder it is handed, and some apps only
/// the image's data. Whatever came, it ends up as files on disk.
///
/// The drag's pasteboard is read at once, while the drop is under way: a promise has to be asked for then, and the
/// pasteboard may hold another drag later. The files themselves come when the source has written them.
final class DroppedFiles: @unchecked Sendable {
    static let imageTypes: [NSPasteboard.PasteboardType] = [.init(UTType.heic.identifier), .init(UTType.jpeg.identifier),
                                                            .png, .tiff]

    /// What the icon's window registers for
    static var pasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) } + imageTypes
    }

    /// The same for SwiftUI's drop targets in the popover
    static var contentTypes: [UTType] {
        [.fileURL, .image] + NSFilePromiseReceiver.readableDraggedTypes.map { UTType(importedAs: $0) }
    }

    /// Whether the drag has anything to send, without asking a source to write its promised files
    static func canTake(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pb.availableType(from: imageTypes) != nil
    }

    /// nil when the drag has nothing to send. Promises are asked for here, so call it while the drop is performed.
    static func take(_ pb: NSPasteboard = NSPasteboard(name: .drag)) -> DroppedFiles? {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return DroppedFiles(ready: urls) }
        let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        if !receivers.isEmpty { return DroppedFiles(promises: receivers) }
        let images = (pb.pasteboardItems ?? []).compactMap(imageFile)
        return images.isEmpty ? nil : DroppedFiles(ready: images)
    }

    /// How long a source may take to write what it promised: Photos may have to download an original from iCloud
    static let promiseTimeout: Duration = .seconds(120)

    private let lock = NSLock()
    private var arrived: [URL] = []
    private var left: Int
    private var waiter: CheckedContinuation<[URL], Never>?

    private init(ready: [URL]) {
        arrived = ready
        left = 0
    }

    private init(promises: [NSFilePromiseReceiver]) {
        // A receiver promises one file per type it names (a Live Photo may bring its picture and its movie)
        left = promises.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        guard let folder = try? Self.newFolder() else {
            left = 0
            return
        }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for receiver in promises {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { [self] url, error in
                came(error == nil ? url : nil)
            }
        }
        Task { [self] in
            try? await Task.sleep(for: Self.promiseTimeout)
            finish()
        }
    }

    /// The files, once every promise is kept or the timeout has passed: what didn't come is left out
    func files() async -> [URL] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if left <= 0 {
                lock.unlock()
                continuation.resume(returning: arrived)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private func came(_ url: URL?) {
        lock.lock()
        if let url { arrived.append(url) }
        left -= 1
        let done = left <= 0 ? waiter : nil
        if done != nil { waiter = nil }
        let files = arrived
        lock.unlock()
        done?.resume(returning: files)
    }

    private func finish() {
        lock.lock()
        left = 0
        let done = waiter
        waiter = nil
        let files = arrived
        lock.unlock()
        done?.resume(returning: files)
    }

    private static func newFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Ferry/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// One dragged image's data as a file, in the format it came in (a TIFF as PNG, which is smaller and opens
    /// everywhere). Each in a folder of its own, so two images keep the same name.
    private static func imageFile(_ item: NSPasteboardItem) -> URL? {
        guard let type = item.availableType(from: imageTypes), let data = item.data(forType: type) else { return nil }
        switch type {
        case .tiff:
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
            return try? ClipboardFile.write(png, name: "Image.png")
        default:
            let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "png"
            return try? ClipboardFile.write(data, name: "Image.\(ext)")
        }
    }
}
