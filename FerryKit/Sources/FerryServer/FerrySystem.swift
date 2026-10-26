import Foundation

/// A notification on this computer about something that arrived.
public struct Notice: Sendable, Equatable {
    /// A notice with the same id replaces the earlier one: files that arrive close together share one notification
    public var id: String
    public var title: String
    public var body: String
    /// The files it is about, for Open and Show in Finder
    public var files: [URL]
    /// The text, for Copy; nil for files, for a text that is already on the clipboard, and for a code or a password,
    /// which Copy reads from the box: Notification Center keeps a notification's info on disk
    public var text: String?
    /// A text's item in the box: Copy reads a code or a password from there, and takes it out (docs/protocol.md ›
    /// Codes and passwords)
    public var item: String?
    /// What arrived is already on the clipboard
    public var copied: Bool

    public init(id: String, title: String, body: String, files: [URL] = [], text: String? = nil, item: String? = nil,
                copied: Bool = false) {
        self.id = id
        self.title = title
        self.body = body
        self.files = files
        self.text = text
        self.item = item
        self.copied = copied
    }
}

/// What the server needs from the computer it runs on. The Mac app answers with AppKit; tests with a fake.
public protocol FerrySystem: Sendable {
    /// The name the phone shows for this computer
    func computerName() async -> String
    /// Seconds since the last key press or mouse move; nil when it can't tell
    func secondsSinceInput() async -> Int?
    /// Where files from devices go
    var downloads: URL { get }
    /// Bytes free on the volume of url; nil when unknown
    func freeSpace(at url: URL) -> Int64?
    /// Onto the clipboard; sensitive: marked so clipboard histories leave it out (docs/protocol.md › Codes and passwords)
    func copy(text: String, sensitive: Bool) async
    func copy(imageAt url: URL, type: String, sensitive: Bool) async
    func notify(_ notice: Notice) async
}
