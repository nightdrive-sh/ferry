import Foundation

/// Sends that wait: what a computer that is asleep or off didn't take stays on the phone until it is back
/// (docs/protocol.md › Clients › Sends that wait). The queue itself is SendQueue, shared with the share extension.
extension FerryModel {
    /// What a computer that is asleep or off didn't take waits on the phone until it is back (docs/protocol.md ›
    /// Clients › Sends that wait)
    func wait(_ payloads: [SendPayload], for machine: URL, name: String) {
        guard let queue else { return }
        do {
            for p in payloads { try queue.add(p, to: machine, name: name) }
        } catch {
            return sendState = .failed("Couldn't keep it to send later")
        }
        manual = nil
        waiting = queue.list()
        hold(.waiting(for: name))
    }

    /// The computers that answered get what waits for them; the share extension's sends are read in too, and those
    /// for a computer no longer listed go
    func deliverWaiting(to answered: Set<URL>) async {
        guard let queue else { return }
        let known = Set(list.machines.map(\.url))
        for s in queue.list() where !known.contains(s.machine) { queue.remove(s.id) }
        waiting = queue.list()
        guard waiting.contains(where: { answered.contains($0.machine) }) else { return }
        for (send, outcome) in await queue.deliver(to: answered, with: backend) { delivered?(send, outcome) }
        waiting = queue.list()
    }

    /// Its row's Cancel
    public func cancel(_ send: QueuedSend) {
        queue?.remove(send.id)
        waiting = queue?.list() ?? []
    }

    /// The computers something waits for: a background wake asks only those
    public var waitingFor: Set<URL> { Set(waiting.map(\.machine)) }
}
