import Foundation

/// One decision about a device: forgotten, or brought back (docs/protocol.md › Forgetting a device).
public struct Forgetting: Codable, Sendable, Equatable {
    /// The device's short tailnet name
    public var device: String
    /// When it was decided, Unix seconds
    public var time: Double
    /// false: brought back, kept so that an older "forgotten" on another computer can't win over it
    public var forgotten: Bool

    public init(device: String, time: Double, forgotten: Bool) {
        self.device = device
        self.time = time
        self.forgotten = forgotten
    }
}

/// The devices the owner forgot on any of their devices (bin/ferry's `forgotten()`), kept in forgotten.json. The
/// other computers' lists come in with their api/ping and are merged in, so a decision reaches every computer.
public actor Forgotten {
    private let path: URL
    private let clock: @Sendable () -> TimeInterval
    public private(set) var all: [Forgetting]

    public init(state: URL, clock: @escaping @Sendable () -> TimeInterval) {
        path = state.appending(path: "forgotten.json")
        self.clock = clock
        // A file edited by hand keeps only what is an entry
        all = Self.merge([], Self.entries(from: (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) }))
    }

    /// The short tailnet names of the devices forgotten now
    public var ids: Set<String> { Set(all.filter(\.forgotten).map(\.device)) }

    /// Forgets a device, or brings it back: decided now, and later than anything this computer knows of it, so it wins
    /// here even over a computer whose clock is ahead
    public func decide(_ device: String, forget: Bool) {
        let device = device.lowercased()   // Tailscale's names are lowercase, however a request writes one
        let old = all.first { $0.device == device }
        let time = old.map { max(clock(), $0.time + 0.001) } ?? clock()
        all = Self.merge(all.filter { $0.device != device }, [Forgetting(device: device, time: time, forgotten: forget)])
        StateFile.save(all, path)
    }

    /// Another computer's list merged into this one's. true when it changed anything (only then is it written).
    @discardableResult
    public func learn(_ theirs: [Forgetting]) -> Bool {
        let merged = Self.merge(all, theirs)
        guard merged != all else { return false }
        all = merged
        StateFile.save(all, path)
        return true
    }

    /// bin/ferry's `merge_forgotten()`: device by device, the later decision wins, forgetting on a tie, so every
    /// computer ends up with the same list whatever order it hears things in
    public static func merge(_ mine: [Forgetting], _ theirs: [Forgetting]) -> [Forgetting] {
        var by = Dictionary(mine.map { ($0.device, $0) }, uniquingKeysWith: { a, _ in a })
        for e in theirs where isDeviceName(e.device) && e.time.isFinite {
            if let old = by[e.device], (e.time, e.forgotten ? 1 : 0) <= (old.time, old.forgotten ? 1 : 0) { continue }
            by[e.device] = e
        }
        return by.values.sorted { $0.device < $1.device }
    }

    /// The entries in another computer's answer (a JSON array); what isn't one is left out
    public static func entries(from json: Any?) -> [Forgetting] {
        guard let list = json as? [Any] else { return [] }
        return list.compactMap { item in
            guard let d = item as? [String: Any], let device = d["device"] as? String, isDeviceName(device),
                  let forgotten = d["forgotten"] as? NSNumber, CFGetTypeID(forgotten) == CFBooleanGetTypeID(),
                  let time = d["time"] as? NSNumber, CFGetTypeID(time) != CFBooleanGetTypeID(), time.doubleValue.isFinite
            else { return nil }
            return Forgetting(device: device, time: time.doubleValue, forgotten: forgotten.boolValue)
        }
    }

    /// A device's short tailnet name, as api/forget takes it: letters, digits and "-", at most 63
    public static func isDeviceName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 63
            && name.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" }
    }
}
