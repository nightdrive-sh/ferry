import Foundation

/// Which APNs host a device token belongs to: a build signed for development gets a sandbox token.
public enum APNsEnvironment: String, Codable, Sendable {
    case production, sandbox
}

/// One address at the relay: where a computer sends the phone's notifications, bound to that computer's VAPID key.
public struct RelayAddress: Codable, Hashable, Sendable {
    public let endpoint: URL
    /// Lets the app check and delete the address; the relay keeps only its hash.
    public let secret: String

    public init(endpoint: URL, secret: String) {
        self.endpoint = endpoint
        self.secret = secret
    }

    public var id: String { endpoint.lastPathComponent }

    /// Whether the address was made by the relay at `base`. One that wasn't is from a relay the app used before.
    public func isAt(_ base: URL) -> Bool {
        endpoint.scheme == base.scheme && endpoint.host() == base.host() && endpoint.port == base.port
    }
}

/// The push relay (push.nightdrive.sh): it holds Apple's push key and passes on what it can't read.
public protocol PushRelay: Sendable {
    /// Where new addresses are made.
    var base: URL { get }
    func register(token: String, env: APNsEnvironment, vapid: String) async throws -> RelayAddress
    /// false once the relay has dropped the address (a dead token, a lost or replaced relay).
    func exists(_ address: RelayAddress) async throws -> Bool
    func delete(_ address: RelayAddress) async throws
}

public struct HTTPRelay: PushRelay {
    static let timeout: TimeInterval = 8

    public let base: URL
    private let session: URLSession

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public func register(token: String, env: APNsEnvironment, vapid: String) async throws -> RelayAddress {
        var req = URLRequest(url: base.appending(path: "v1/register"), timeoutInterval: Self.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["token": token, "env": env.rawValue, "vapid": vapid])
        let (data, _) = try await load(req)
        return try JSONDecoder().decode(RelayAddress.self, from: data)
    }

    public func exists(_ address: RelayAddress) async throws -> Bool {
        try await load(request(address, method: "GET"), allowing: [404]).1 != 404
    }

    public func delete(_ address: RelayAddress) async throws {
        _ = try await load(request(address, method: "DELETE"))
    }

    private func request(_ address: RelayAddress, method: String) -> URLRequest {
        var req = URLRequest(url: address.endpoint, timeoutInterval: Self.timeout)
        req.httpMethod = method
        req.setValue("Bearer \(address.secret)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func load(_ req: URLRequest, allowing: Set<Int> = []) async throws -> (Data, Int) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw FerryError.unreachable(machine: base.host() ?? "the relay")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400, !allowing.contains(status) {
            throw FerryError.refused(status: status, message: String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (data, status)
    }
}
