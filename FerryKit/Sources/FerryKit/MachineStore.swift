import Foundation

/// The machine list on disk. The app passes the App Group's defaults (group.fi.feature.ferry), so the share and
/// notification extensions read the same list.
public struct MachineStore: @unchecked Sendable {   // UserDefaults is thread-safe
    static let key = "machines"
    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> MachineList {
        guard let data = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode(MachineList.self, from: data) else { return MachineList() }
        return list
    }

    public func save(_ list: MachineList) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.key) }
    }
}
