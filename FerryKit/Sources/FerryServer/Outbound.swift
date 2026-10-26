import Foundation

/// Requests the server makes: to push services, and to the owner's other computers through Tailscale.
public protocol Outbound: Sendable {
    func data(_ request: URLRequest) async throws -> (status: Int, body: Data)
    /// The file streams from disk, never read whole. progress gets the fraction of it sent, 0…1.
    func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws
        -> (status: Int, body: Data)
}

public struct URLSessionOutbound: Outbound {
    public init() {}

    public func data(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (body, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }

    public func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws
        -> (status: Int, body: Data) {
        let (body, response) = try await URLSession.shared.upload(for: request, fromFile: file,
                                                                   delegate: UploadProgress(report: progress))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }
}

/// Passes on how much of an upload's body has gone
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// A small JSON file in the state folder, written whole: atomically, and with mode 0600 when it holds secrets.
enum StateFile {
    static func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func save(_ value: some Encodable, _ url: URL, secret: Bool = false) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value) else { return }
        // Written beside it with the right mode first, then renamed over it: never a moment with the file readable
        let tmp = url.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: secret ? 0o600 : 0o644]) else { return }
        _ = rename(tmp.path, url.path)
    }
}
