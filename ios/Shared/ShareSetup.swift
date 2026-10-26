import FerryKit
import Foundation
import UserNotifications

/// The share view's model, made the same way by the share extension and by the app's debug launch arguments.
@MainActor
enum ShareSetup {
    static let appGroup = "group.fi.feature.ferry"
    /// Before a computer counts as not answering: shorter than the app's 8 s, so a sleeping one doesn't hold up the
    /// send to the only one that answers (asked twice, so about 5 s at worst)
    static let askTimeout: TimeInterval = 2.5
    /// One background session per process, so one uploader. An upload that ends with no sheet waiting (after Continue
    /// in Background) and fails is told as a notification, as the app tells one iOS woke it for.
    static let uploader = BackgroundUploader(appGroup: appGroup, onOrphanFailure: notifyFailure)

    /// "Couldn't send photo.jpg to MacBook", if notifications are allowed.
    nonisolated static func notifyFailure(_ note: UploadNote) {
        let content = UNMutableNotificationContent()
        content.body = "Couldn't send \(note.name) to \(note.machineName)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The computers the app knows (read, never written: the app is the list's only writer), and the share's files
    /// copied into the App Group's container, where they outlive the extension while they upload.
    static func model(loading shared: @escaping @Sendable () async -> [Shared]) -> ShareModel {
        let defaults = UserDefaults(suiteName: appGroup) ?? .standard
        let machines = MachineStore(defaults: defaults).load().machines
        let folder = UploadCopies.folder(appGroup: appGroup)
            ?? FileManager.default.temporaryDirectory.appending(path: "Uploads")
        return ShareModel(machines: machines, load: {
            let found = await shared()
            let payloads = ShareContent.payloads(found, copyingInto: folder)
            // The loader's own copies in tmp: the container's copies are what upload, and a video's blocks would
            // otherwise stay taken until iOS empties tmp
            let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path()
            for case .file(let url) in found where url.standardizedFileURL.path().hasPrefix(tmp) {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            return payloads
        }, ask: HTTPBackend(timeout: askTimeout), send: HTTPBackend(), files: uploader)
    }
}
