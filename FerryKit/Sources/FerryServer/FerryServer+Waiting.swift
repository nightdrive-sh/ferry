import FerryKit
import Foundation

/// Sends that wait for a computer that was asleep or off, and telling the phones this Mac is back
/// (docs/protocol.md › Clients › Sends that wait, › Notifications › The "awake" push). bin/ferry's outbox.py and
/// wake.py do the same on Linux.
extension FerryServer {
    /// Seconds between looks at Tailscale while anything waits
    static let waitingEvery = 15
    /// Seconds before a computer that is online but didn't take a send is tried again (its Ferry may not be up yet)
    static let afterMiss: TimeInterval = 60
    /// How long after a start or a wake the "awake" push is tried, and how often, before it gives up
    static let announceFor: TimeInterval = 300
    static let announceEvery = 15

    /// Newest first, for the popover
    public func waiting() async -> [WaitingSend] {
        await outbox.list().reversed()
    }

    public func cancelWaiting(_ id: String) async {
        await outbox.remove(id)
    }

    /// The sends whose computer Tailscale has online again go now; one that is online but doesn't take it is asked
    /// again after afterMiss. Each that goes, or that its computer refused, is said in a notification.
    func deliverWaiting() async {
        guard !(await outbox.list().isEmpty) else { return }
        await outbox.drop(devices: await forgotten.ids)
        let online = Set((await tailnet.view(force: true)).onlineComputers.compactMap { $0.split(separator: ".").first.map(String.init) })
        let now = clock()
        for send in await outbox.list() where online.contains(send.device) {
            if let at = missedAt[send.device], now - at < Self.afterMiss { continue }
            guard let base = base(of: send.device) else { continue }
            switch await deliver(send, to: base) {
            case .missed:
                missedAt[send.device] = now
            case .refused(let said):
                missedAt[send.device] = nil
                await outbox.remove(send.id)
                await system.notify(Notice(id: "waiting-\(send.id)", title: "Couldn't send to \(send.name)",
                                           body: "\(send.what): \(said)"))
            case .sent:
                missedAt[send.device] = nil
                await outbox.remove(send.id)
                let age = Age.short(now - send.time)
                await system.notify(Notice(id: "waiting-\(send.id)", title: "Delivered to \(send.name)",
                                           body: age == "now" ? send.what : "\(send.what) · sent \(age) ago"))
            }
        }
    }

    /// One waiting send, without `clip`: put onto the other clipboard later, it would replace whatever was copied
    /// there since. Each file it takes is crossed off, so a send that breaks off goes on from there.
    private func deliver(_ send: WaitingSend, to base: URL) async -> Delivered {
        let delivery = Delivery(outbound: outbound)
        if send.kind == "text" { return await delivery.text(send.text ?? "", clip: false, to: base) }
        for file in send.files {
            let result = await delivery.file(await outbox.url(of: file, in: send), name: file.name, clip: false, to: base)
            guard result == .sent else { return result }
            await outbox.crossOff(file, of: send.id)
        }
        return .sent
    }

    /// The silent "awake" push to the iPhone apps, once this Mac can be reached (Tailscale on, Ferry published):
    /// called at launch and when the Mac wakes from sleep. Tried for announceFor seconds; one call at a time.
    public func announceAwake() async {
        guard !announcing else { return }
        announcing = true
        defer { announcing = false }
        let end = clock() + Self.announceFor
        while !Task.isCancelled {
            if await served() == .published {
                let went = await pusher.wake(title: await system.computerName())
                if went != false { return }   // nil: no app to tell
            }
            if clock() >= end { return }
            try? await Task.sleep(for: .seconds(Self.announceEvery))
        }
    }
}
