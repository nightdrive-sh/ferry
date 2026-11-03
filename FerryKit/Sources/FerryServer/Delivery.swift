import FerryKit
import Foundation

/// How a computer took a send.
enum Delivered: Equatable {
    case sent
    /// It didn't answer (asleep, off, its Ferry not up yet): the send waits for it
    case missed
    /// It answered no (no room, too big), with what it said
    case refused(String)

    /// tailscale serve answers 502–504 while the computer's own Ferry isn't up yet: that is no answer from it
    static func from(_ result: (status: Int, body: Data)?) -> Delivered {
        guard let result else { return .missed }
        if (200..<300).contains(result.status) { return .sent }
        if (502...504).contains(result.status) { return .missed }
        let said = String(decoding: result.body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .refused(said.isEmpty ? "\(result.status)" : said)
    }
}

/// The requests that send to another computer, as the iPhone app makes them, so a computer sees the Mac's sends exactly
/// as the phone's.
struct Delivery {
    let outbound: any Outbound

    func text(_ text: String, clip: Bool, to base: URL) async -> Delivered {
        var req = URLRequest(url: base.appending(path: "api/text"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("1", forHTTPHeaderField: "X-Ferry")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "clip": clip])
        return .from(try? await outbound.data(req))
    }

    func file(_ file: URL, name: String, clip: Bool, to base: URL,
              progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Delivered {
        var req = HTTPBackend.uploadRequest(base, name: name, type: MIME.type(forName: name), clip: clip)
        req.timeoutInterval = 30
        return .from(try? await outbound.upload(req, file: file, progress: progress))
    }
}

/// What became of a send.
public enum SendResult: Equatable, Sendable {
    case sent
    /// The computer is asleep or off: the send waits on this Mac until it is back (Outbox)
    case waiting
    /// Why not
    case failed(String)
}
