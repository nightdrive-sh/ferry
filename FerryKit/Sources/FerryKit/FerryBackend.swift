import Foundation

/// What Ferry asks of its computers (docs/protocol.md). The app uses `HTTPBackend`, and `DemoBackend` for its demo;
/// tests plug in here too.
public protocol FerryBackend: Sendable {
    /// The computer's name.
    func ping(_ machine: URL) async throws -> String
    func items(_ machine: URL) async throws -> ItemsResponse
    func machines(_ machine: URL) async throws -> MachinesResponse
    /// `progress` gets 0…1 while a file uploads.
    func send(_ payload: SendPayload, to machine: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    /// The file, in a temporary folder of its own under its own name (so a share sheet shows that name).
    func download(_ item: Item, from machine: URL) async throws -> URL
    func remove(_ id: String, on machine: URL) async throws
    /// Everything the computer left for the phone, out of its box.
    func clearReceived(on machine: URL) async throws
    /// The phone's notifications from this computer, through the relay address `endpoint`. Direct: the computer
    /// notifies about its own items only, and no longer through the PWA on the same phone.
    func subscribe(_ endpoint: URL, keys: PushKeys, on machine: URL) async throws
    func unsubscribe(_ endpoint: URL, on machine: URL) async throws
    /// A computer forgotten on every device, through this computer (`api/forget`).
    func forget(_ device: String, on machine: URL) async throws
    /// A forgotten computer brought back (`api/unforget`): setting it up again is doing so by hand.
    func unforget(_ device: String, on machine: URL) async throws
}

public enum SendPayload: Sendable, Equatable {
    /// `clip`: it was the phone's clipboard, so it goes straight onto the computer's.
    case text(String, clip: Bool)
    case file(URL, name: String, type: String, clip: Bool)
}
