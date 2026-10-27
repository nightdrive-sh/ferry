import Foundation

/// One of the owner's other devices, as the menu's device list shows it.
public struct Device: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case computer, phone, tablet }

    /// The short tailnet name
    public var id: String
    public var name: String
    public var kind: Kind
    public var online: Bool
    /// A computer in use when last asked
    public var inUse: Bool

    public init(id: String, name: String, kind: Kind, online: Bool, inUse: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.online = online
        self.inUse = inUse
    }
}

/// The phones and tablets that have used Ferry on this computer (docs/protocol.md › Forgetting a device), kept in
/// phones.json: only those are in the device list, not every phone on the tailnet.
public actor Phones {
    private let path: URL
    public private(set) var names: Set<String>

    public init(state: URL) {
        path = state.appending(path: "phones.json")
        if let kept = StateFile.load([String].self, path) {
            names = Set(kept)
        } else {
            // A Ferry from before this list: a phone subscribed here has used it, so an update doesn't empty the list
            names = Set(Pusher.saved(in: state).map(\.device).filter(Forgotten.isDeviceName))
            if !names.isEmpty { StateFile.save(names.sorted(), path) }
        }
    }

    /// A phone or a tablet asked: written only when it is new, since every request records its asker
    public func used(by name: String) {
        guard Forgotten.isDeviceName(name), !names.contains(name) else { return }
        names.insert(name)
        StateFile.save(names.sorted(), path)
    }
}

enum Devices {
    /// Without the forgotten ones
    static func list(view: TailnetView, known: [KnownComputer], phones: Set<String>, forgotten: Set<String>) -> [Device] {
        list(view: view, known: known, phones: phones).filter { !forgotten.contains($0.id) }
    }

    /// bin/ferry's `devices()`: computers are the ones found running Ferry (machines.json), asleep while Tailscale
    /// says they're offline; phones and tablets are Tailscale's that have used Ferry here (`Phones`).
    static func list(view: TailnetView, known: [KnownComputer], phones used: Set<String>) -> [Device] {
        let peers = Dictionary(view.peers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let computers = known.sorted { $0.name.lowercased() < $1.name.lowercased() }.compactMap { m -> Device? in
            guard let p = peers[m.id], !TailnetView.phoneOSes.contains(p.os) else { return nil }
            return Device(id: m.id, name: m.name, kind: .computer, online: p.online, inUse: p.online && m.idle == 0)
        }
        let phones = view.peers.filter { TailnetView.phoneOSes.contains($0.os) && used.contains($0.id) }.sorted { $0.id < $1.id }.map { p in
            let tablet = (p.id + p.hostName).lowercased().contains("ipad") || p.id.lowercased().contains("tablet")
            return Device(id: p.id, name: p.id, kind: tablet ? .tablet : .phone, online: p.online, inUse: false)
        }
        return computers + phones
    }

    /// bin/ferry's `target()`: the device picked last while it's still one of the owner's, else a phone (an online one
    /// first), else another computer
    static func target(_ devices: [Device], picked: String?) -> Device? {
        if let picked, let d = devices.first(where: { $0.id == picked }) { return d }
        let phones = devices.filter { $0.kind != .computer }
        return phones.first { $0.online } ?? phones.first ?? devices.first
    }

    /// bin/ferry's `file_paths()`: files as they are, a folder's files below it, without hidden ones (no .git)
    static func files(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for url in urls {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &dir) else { continue }
            if !dir.boolValue { out.append(url); continue }
            let found = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            let inside = (found?.allObjects as? [URL] ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            out += inside.sorted { $0.path < $1.path }
        }
        return out
    }
}
