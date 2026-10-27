import FerryKit
import Foundation
import os

/// A phone's push subscription, as `api/subscribe` gives it, with the device it came from.
public struct Subscription: Codable, Sendable, Equatable {
    public struct Keys: Codable, Sendable, Equatable {
        public var p256dh: String
        public var auth: String
        public init(p256dh: String, auth: String) {
            self.p256dh = p256dh
            self.auth = auth
        }
    }

    public var endpoint: String
    public var keys: Keys
    /// The subscribing device's tailnet name, "your phone" when the computer couldn't name it
    public var device: String
    public var time: Double
    /// The iPhone app's: it subscribes on every computer and hears about each one's items from that one
    public var direct: Bool?

    public init(endpoint: String, keys: Keys, device: String, time: Double, direct: Bool?) {
        self.endpoint = endpoint
        self.keys = keys
        self.device = device
        self.time = time
        self.direct = direct
    }
}

/// Notifications to the owner's phones (docs/protocol.md › Notifications): Web Push to their subscriptions here, and a
/// request to pass it on to the computers whose page a phone was added from (`relays`).
public actor Pusher {
    static let log = Logger(subsystem: "fi.feature.ferry.mac", category: "push")

    private let state: URL
    private let key: VAPIDKey
    private let config: ServerConfig
    private let outbound: any Outbound
    private var subs: [Subscription]
    private var vias: [String]

    public init(state: URL, key: VAPIDKey, config: ServerConfig, outbound: any Outbound) {
        self.state = state
        self.key = key
        self.config = config
        self.outbound = outbound
        subs = Self.saved(in: state)
        vias = StateFile.load([String].self, state.appending(path: "relays.json")) ?? []
    }

    /// The subscriptions kept in a state folder (push.json)
    static func saved(in state: URL) -> [Subscription] {
        StateFile.load([Subscription].self, state.appending(path: "push.json")) ?? []
    }

    public var publicKey: String { key.publicKey }

    public func subscriptions() -> [Subscription] { subs }
    public func relays() -> [String] { vias }

    /// The same endpoint again replaces the old one, so a phone may subscribe at any time, and a direct one (the
    /// app's) the same device's earlier direct ones, so an app installed again doesn't leave its old address getting
    /// every notification. A device named "your phone" could be anyone's, so it replaces nothing.
    public func subscribe(_ s: Subscription) {
        let named = s.device != "your phone"
        subs = subs.filter { $0.endpoint != s.endpoint && !(named && s.direct == true && $0.direct == true && $0.device == s.device) }
            + [s]
        saveSubs()
    }

    /// A forgotten phone's subscriptions go: it gets no more notifications from here
    public func drop(devices: Set<String>) {
        guard subs.contains(where: { devices.contains($0.device) }) else { return }
        subs.removeAll { devices.contains($0.device) }
        saveSubs()
    }

    public func unsubscribe(endpoint: String) {
        subs.removeAll { $0.endpoint == endpoint }
        saveSubs()
    }

    /// A computer whose page a phone switched to this one from: notifications about this one go through it too
    public func addRelay(_ via: String) {
        guard !vias.contains(via) else { return }
        vias.append(via)
        StateFile.save(vias, state.appending(path: "relays.json"))
    }

    /// bin/ferry's `targets()` and `recipients()`: the app's direct subscription quiets the same phone's page, a
    /// notification passed on from another computer isn't for the app (it hears from that computer itself), and a
    /// device named "your phone" could be anyone's, so it replaces nothing. device: only that phone's.
    public static func recipients(_ subs: [Subscription], relayed: Bool, device: String) -> [Subscription] {
        let direct = Set(subs.filter { $0.direct == true && $0.device != "your phone" }.map(\.device))
        return subs.filter { s in
            !(relayed && s.direct == true) && (s.direct == true || !direct.contains(s.device))
                && (device.isEmpty || s.device == device)
        }
    }

    /// A notification on the subscribed phones, and through the relays on the phones that added another computer's
    /// page. machine: the computer it is about when another one passed it on ("" for this one). item: what a tap
    /// opens. device: only that phone. own: this computer's address. A subscription the push service no longer knows
    /// (404, 410) goes.
    public func push(title: String, body: String, machine: String = "", item: BoxItem? = nil, device: String = "",
                     own: String) async {
        // A page shows the body as it is, also one this goes to through a relay (docs/protocol.md › Codes and passwords)
        let body = item?.isSecret == true ? Secret.hidden : body
        let content = WebPush.payload(title: title, body: body, machine: machine, item: item, limit: config.pushPayload)
        let targets = Self.recipients(subs, relayed: !machine.isEmpty, device: device)
        let relayTo = machine.isEmpty ? vias.filter { $0 != own } : []
        let gone = await withTaskGroup(of: String?.self) { group in
            for via in relayTo {
                group.addTask { await self.relay(via: via, title: title, body: body, own: own, device: device); return nil }
            }
            for sub in targets {
                group.addTask { await self.send(content, to: sub) }
            }
            var out: [String] = []
            for await g in group { if let g { out.append(g) } }
            return out
        }
        if !gone.isEmpty {
            subs.removeAll { gone.contains($0.endpoint) }
            saveSubs()
        }
    }

    /// The endpoint when the push service says the subscription is gone
    private func send(_ content: Data, to sub: Subscription) async -> String? {
        guard let url = URL(string: sub.endpoint) else { return sub.endpoint }
        do {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.httpBody = try WebPush.encrypt(content, p256dh: sub.keys.p256dh, auth: sub.keys.auth)
            req.setValue(try key.authorization(for: url, now: Date(), contact: config.pushContact), forHTTPHeaderField: "Authorization")
            req.setValue(String(config.pushTTL), forHTTPHeaderField: "TTL")
            req.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue("high", forHTTPHeaderField: "Urgency")
            let (status, _) = try await outbound.data(req)
            if status == 404 || status == 410 { return sub.endpoint }
            if status >= 300 { Self.log.error("push to \(url.host() ?? "", privacy: .public): \(status)") }
        } catch {
            Self.log.error("push failed: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    /// Asks the computer at via to notify its phones (or the one named device) about this one
    private func relay(via: String, title: String, body: String, own: String, device: String) async {
        guard let url = URL(string: via + "api/relay-push") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("1", forHTTPHeaderField: "X-Ferry")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        req.httpBody = try? encoder.encode(["title": title, "body": body, "machine": own, "device": device])
        do {
            _ = try await outbound.data(req)
        } catch {
            Self.log.error("relay through \(via, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveSubs() {
        StateFile.save(subs, state.appending(path: "push.json"), secret: true)
    }
}
