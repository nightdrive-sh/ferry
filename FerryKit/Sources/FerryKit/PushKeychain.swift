import Foundation
import Security

/// The notification keys in the Keychain, in a group the app and its notification extension share. Readable after the
/// first unlock: most notifications arrive on a locked phone, and with the default ("when unlocked") the extension
/// couldn't open them. Never synchronized: a key belongs to this phone's subscriptions.
public struct PushKeychain: Sendable {
    public static let accessGroup = "279G2UNHPN.fi.feature.ferry.shared"
    static let service = "fi.feature.ferry.push"

    private let group: String

    public init(accessGroup: String = PushKeychain.accessGroup) { group = accessGroup }

    static func attributes(group: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "keys",
         kSecAttrAccessGroup as String: group,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
         kSecAttrSynchronizable as String: false]
    }

    public func load() -> PushKeys? {
        var query = Self.attributes(group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(PushKeys.self, from: data)
    }

    public func loadOrCreate() throws -> PushKeys {
        if let keys = load() { return keys }
        let keys = PushKeys.generate()
        var item = Self.attributes(group: group)
        item[kSecValueData as String] = try JSONEncoder().encode(keys)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return keys
    }

    public func delete() {
        SecItemDelete(Self.attributes(group: group) as CFDictionary)
    }
}
