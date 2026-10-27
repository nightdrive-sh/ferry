import Foundation

/// FerryBackend over HTTPS to each computer's `tailscale serve` address.
public struct HTTPBackend: FerryBackend {
    public static let timeout: TimeInterval = 8     // before a computer counts as unreachable (the PWA's TIMEOUT)
    static let machinesTimeout: TimeInterval = 15   // api/machines asks every other computer first
    static let downloadTimeout: TimeInterval = 120

    private let session: URLSession
    /// Before a computer counts as unreachable; the share sheet asks with less, so a sleeping one doesn't hold it up
    private let wait: TimeInterval

    public init(configuration: URLSessionConfiguration = .default, timeout: TimeInterval = timeout) {
        session = URLSession(configuration: configuration)
        wait = timeout
    }

    public func ping(_ machine: URL) async throws -> String {
        struct Ping: Decodable { let computer: String }
        return try await get(machine, "api/ping", as: Ping.self).computer
    }

    public func items(_ machine: URL) async throws -> ItemsResponse {
        try await get(machine, "api/items", as: ItemsResponse.self)
    }

    public func machines(_ machine: URL) async throws -> MachinesResponse {
        try await get(machine, "api/machines", as: MachinesResponse.self, timeout: Self.machinesTimeout)
    }

    public func send(_ payload: SendPayload, to machine: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch payload {
        case .text(let text, let clip):
            var req = request(machine, "api/text", method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "clip": clip])
            _ = try await load(req, machine)
        case .file(let file, let name, let type, let clip):
            // The request's 8 s is an idle timeout, reset by every chunk sent: a big file that keeps moving takes as long
            // as it takes (the session's resource timeout is days), and a computer that never answers fails as fast as
            // a text to it does
            let req = Self.uploadRequest(machine, name: name, type: type, clip: clip, timeout: wait)
            let (data, response) = try await mapErrors(machine) {
                try await session.upload(for: req, fromFile: file, delegate: UploadProgress(progress))
            }
            try check(response, data)
        }
    }

    public func download(_ item: Item, from machine: URL) async throws -> URL {
        var req = request(machine, "api/file/\(item.id)")
        req.timeoutInterval = Self.downloadTimeout
        let (temp, response) = try await mapErrors(machine) { try await session.download(for: req) }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw FerryError.refused(status: http.statusCode, message: (try? String(contentsOf: temp, encoding: .utf8)) ?? "")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: item.name ?? item.id)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    public func remove(_ id: String, on machine: URL) async throws {
        _ = try await load(request(machine, "api/remove", method: "POST", query: [("id", id)]), machine)
    }

    public func clearReceived(on machine: URL) async throws {
        _ = try await load(request(machine, "api/clear", method: "POST", query: [("to", "phone")]), machine)
    }

    public func subscribe(_ endpoint: URL, keys: PushKeys, on machine: URL) async throws {
        try await post(machine, "api/subscribe", ["endpoint": endpoint.absoluteString,
                                                  "keys": ["p256dh": keys.p256dh, "auth": keys.authString], "direct": true])
    }

    public func unsubscribe(_ endpoint: URL, on machine: URL) async throws {
        try await post(machine, "api/unsubscribe", ["endpoint": endpoint.absoluteString])
    }

    public func forget(_ device: String, on machine: URL) async throws {
        try await post(machine, "api/forget", ["device": device])
    }

    public func unforget(_ device: String, on machine: URL) async throws {
        try await post(machine, "api/unforget", ["device": device])
    }

    public func unforgetSelf(on machine: URL) async throws {
        try await post(machine, "api/unforget", ["self": true])
    }

    /// `api/upload` for one file, as `send` makes it: also what the share extension's background session sends.
    public static func uploadRequest(_ machine: URL, name: String, type: String, clip: Bool,
                                     timeout: TimeInterval = timeout) -> URLRequest {
        var query = [("name", name), ("type", type)]
        if clip { query.append(("clip", "1")) }
        return request(machine, "api/upload", method: "POST", query: query, timeout: timeout)
    }

    // MARK: -

    private func post(_ machine: URL, _ path: String, _ body: [String: Any]) async throws {
        var req = request(machine, path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await load(req, machine)
    }

    /// Query values escape the characters that would split or end them (`&`, `=`, `+`, `#`), which `URLComponents`
    /// otherwise leaves alone: a file named "Lasku & kuitti #2.pdf" has to arrive whole.
    private static let queryValue: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: "&=+#?")
        return s
    }()

    private func request(_ machine: URL, _ path: String, method: String = "GET", query: [(String, String)] = []) -> URLRequest {
        Self.request(machine, path, method: method, query: query, timeout: wait)
    }

    private static func request(_ machine: URL, _ path: String, method: String, query: [(String, String)],
                                timeout: TimeInterval) -> URLRequest {
        var url = machine.appending(path: path)
        if !query.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.percentEncodedQuery = query.map { k, v in
                "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: Self.queryValue) ?? "")"
            }.joined(separator: "&")
            url = c.url ?? url
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("1", forHTTPHeaderField: "X-Ferry")
        return req
    }

    private func get<T: Decodable>(_ machine: URL, _ path: String, as: T.Type, timeout: TimeInterval? = nil) async throws -> T {
        var req = request(machine, path)
        if let timeout { req.timeoutInterval = timeout }
        return try JSONDecoder().decode(T.self, from: try await load(req, machine))
    }

    private func load(_ req: URLRequest, _ machine: URL) async throws -> Data {
        let (data, response) = try await mapErrors(machine) { try await session.data(for: req) }
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw FerryError.refused(status: http.statusCode, message: text)
    }

    /// Any transport failure means the computer can't be reached: the person can't tell a timeout from a TLS failure, and
    /// the fix is the same (Tailscale on, the computer awake, Ferry running).
    private func mapErrors<T>(_ machine: URL, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()   // the poll was stopped (the app left the screen): the computer said nothing
        } catch let e as URLError {
            throw FerryError.unreachable(machine: String(machine.host()?.split(separator: ".").first ?? ""),
                                         timedOut: e.code == .timedOut)
        }
    }
}

/// Passes an upload's progress on as a 0…1 fraction.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}
