import AppKit
import FerryKit
import FerryServer
import Synchronization
import SystemConfiguration
import UniformTypeIdentifiers
import UserNotifications

/// The Mac's side of the server: its name, how long since it was used, Downloads, the clipboard and notifications.
struct MacSystem: FerrySystem {
    var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    func computerName() async -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    func secondsSinceInput() async -> Int? {
        // Any input event: keys, the mouse, the trackpad
        guard let any = CGEventType(rawValue: ~0) else { return nil }
        return Int(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any))
    }

    func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    func copy(text: String, sensitive: Bool) async {
        await MainActor.run { NSPasteboard.general.put(text, concealed: sensitive) }
    }

    func copy(imageAt url: URL, type: String, sensitive: Bool) async {
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            if let image = NSImage(contentsOf: url) {
                pb.writeObjects([image])
            } else if let data = try? Data(contentsOf: url), let uti = UTType(mimeType: type) {
                pb.setData(data, forType: NSPasteboard.PasteboardType(uti.identifier))
            }
            if sensitive { pb.conceal() }
        }
    }

    func notify(_ notice: Notice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        if let text = notice.text {
            content.categoryIdentifier = Notifications.text
            content.userInfo = ["text": text]
        } else if let item = notice.item {   // a code or a password: only its place in the box is kept on disk
            content.categoryIdentifier = Notifications.text
            content.userInfo = ["item": item]
        } else if !notice.files.isEmpty {
            content.categoryIdentifier = Notifications.file
            content.userInfo = ["files": notice.files.map(\.path)]
        }
        // The same id replaces the earlier notification: files that arrive together share one
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }
}

/// The notifications' buttons: Copy on a text, Open and Show in Finder on files.
final class Notifications: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let text = "text"
    static let file = "file"
    static let shared = Notifications()
    /// Copy on a code's or a password's notification, by its item's id: the menu's model reads it from the box,
    /// copies it and takes it out (nothing, once it has left)
    let copyItem = Mutex<(@Sendable (String) async -> Void)?>(nil)

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.text, actions: [UNNotificationAction(identifier: "copy", title: "Copy")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.file, actions: [UNNotificationAction(identifier: "open", title: "Open"),
                                                                     UNNotificationAction(identifier: "show", title: "Show in Finder")],
                                   intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A menu bar app is always the active one, so notifications show anyway
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let files = (info["files"] as? [String] ?? []).map { URL(filePath: $0) }
        let text = info["text"] as? String
        let action = response.actionIdentifier
        if text == nil, let item = info["item"] as? String, action == "copy" || action == UNNotificationDefaultActionIdentifier {
            if let copyItem = copyItem.withLock({ $0 }) { await copyItem(item) }
            return
        }
        await MainActor.run {
            if let text, action == "copy" || action == UNNotificationDefaultActionIdentifier {
                NSPasteboard.general.put(text, concealed: Secret.looksLike(text))
            } else if action == "show" {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            } else if let first = files.first {
                // Several files open their folder, one file opens itself
                NSWorkspace.shared.open(files.count == 1 ? first : first.deletingLastPathComponent())
            }
        }
    }
}
