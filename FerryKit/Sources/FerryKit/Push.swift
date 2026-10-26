import Foundation

/// What a computer's notification says once decrypted (docs/protocol.md › The push payload). `id`, `kind` and `text`
/// are missing on a test notification; `text` also on a text too long to fit, which the tap then fetches.
public struct PushMessage: Decodable, Equatable, Sendable {
    public let title: String
    public let body: String
    /// The computer the item is on, "" for the sender itself (always "" on the app's direct subscriptions).
    public let machine: String
    public let id: String?
    public let kind: Item.Kind?
    public let text: String?
    /// The text looks like a code or a password, and `body` says so in its place
    public let secret: Bool?

    /// What the notification shows: a code or a password never, also from a computer from before the rule, which sends
    /// the text itself as the body. A file's name is shown whatever it looks like.
    public var shownBody: String {
        // Separate statements, not one expression: Swift 6.4's optimizer (SemanticARCOpts) crashes on the single
        // `&& (|| looksLike(text ?? body)) ? :` form in a release build
        guard kind == .text else { return body }
        if secret == true { return Secret.hidden }
        let shown = text ?? body
        return Secret.looksLike(shown) ? Secret.hidden : body
    }
}

/// A notification as APNs delivers it, opened: the relay address it came through and the message.
public struct PushNotice: Equatable, Sendable {
    /// The relay address id (the payload's `a`): it tells which computer sent it, as the relay can't.
    public let address: String
    public let message: PushMessage

    /// `userInfo` from APNs: `a` the address id, `m` the encrypted body in standard base64. nil when anything is
    /// missing or doesn't open, so the caller keeps the fallback text.
    public static func open(_ userInfo: [AnyHashable: Any], keys: PushKeys) -> PushNotice? {
        guard let address = userInfo["a"] as? String, let m = userInfo["m"] as? String,
              let body = Data(base64Encoded: m),
              let plain = try? PushCrypto.decrypt(body, with: keys),
              let message = try? JSONDecoder().decode(PushMessage.self, from: plain) else { return nil }
        return PushNotice(address: address, message: message)
    }
}
