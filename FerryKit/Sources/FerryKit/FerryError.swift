import Foundation

public enum FerryError: Error, Equatable, Sendable {
    /// No answer: a timeout, no route (Tailscale off, the computer asleep) or a TLS failure. `machine` is its short name.
    /// `timedOut`: it was asked and said nothing in time, which a computer just set up does until it has its HTTPS
    /// certificate, rather than an answer that is no (no such name, nothing listening).
    case unreachable(machine: String, timedOut: Bool = false)
    /// The computer answered with an error; `message` is its own text, e.g. 404 "Not in the box any more".
    case refused(status: Int, message: String)
    case emptyClipboard
    case noMachine

    /// What the app says, in place.
    public var message: String {
        switch self {
        case .unreachable(let machine, _): "Can't reach \(machine)"
        case .refused(_, let message): message
        case .emptyClipboard: "Clipboard is empty"
        case .noMachine: "No computer set up"
        }
    }
}
