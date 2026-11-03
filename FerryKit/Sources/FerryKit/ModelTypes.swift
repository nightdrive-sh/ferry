import Foundation

/// Something a computer left for the phone, with the computer it is on.
public struct Received: Codable, Identifiable, Hashable, Sendable {
    public let item: Item
    public let machine: URL
    /// The computer's name: items for the phone carry no `from`, their sender is the computer itself.
    public let machineName: String
    public var id: String { Self.id(machine: machine, item: item.id) }

    public static func id(machine: URL, item: String) -> String { machine.absoluteString + "#" + item }
}

/// What a tapped notification leads to.
public enum NoticeResult: Equatable, Sendable {
    /// A text to put on the clipboard: always the whole text, never the notification's cut preview.
    case copy(String)
    case shown
    /// A long text whose computer doesn't answer: nothing is copied.
    case unreachable(name: String)
    /// No longer in the box.
    case gone
}

public enum SendState: Equatable, Sendable {
    case idle
    case sending(Double)
    case sent(to: String)
    /// The computer is asleep or off: the send waits on the phone until it is back (SendQueue)
    case waiting(for: String)
    case failed(String)
}
