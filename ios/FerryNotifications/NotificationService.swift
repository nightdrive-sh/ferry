import FerryKit
import UserNotifications

/// Opens what a computer sent before iOS shows it: the relay delivers only encrypted bytes and a fallback line
/// ("Something arrived…"), and this puts the computer's name and the text itself, or the file's name, in their place:
/// a code or a password says only that it is one (docs/protocol.md › Codes and passwords).
/// Anything that fails leaves the fallback as it is.
final class NotificationService: UNNotificationServiceExtension {
    private var content: UNMutableNotificationContent?
    private var deliver: ((UNNotificationContent) -> Void)?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        deliver = handler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return handler(request.content) }
        self.content = content
        if let keys = PushKeychain().load(), let notice = PushNotice.open(request.content.userInfo, keys: keys) {
            let m = notice.message
            content.title = m.title
            content.body = m.shownBody   // never a code or a password, whatever the lock screen shows
            content.threadIdentifier = notice.address   // one computer's notifications together
            var info: [String: Any] = ["address": notice.address, "machine": m.machine]
            if let id = m.id { info["id"] = id }
            if let kind = m.kind { info["kind"] = kind.rawValue }
            if let text = m.text { info["text"] = text }
            content.userInfo["notice"] = info
        }
        handler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let deliver, let content { deliver(content) }
    }
}
