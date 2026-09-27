import Foundation
import Security

/// Bookkeeping keys for syncing the external services settings through iCloud.
nonisolated enum ExternalServicesSync {
    static let updatedAtKey = "external_services_updated_at"
    static let syncedAtKey = "external_services_synced_at"
}

/// Everything another device needs to use the same Last.fm connection.
nonisolated struct LastFMCloudSnapshot: Equatable, Sendable {
    var isEnabled: Bool
    var username: String
    var apiKey: String
    var sharedSecret: String
    var sessionKey: String
}

/// Stores the Last.fm settings. The toggle and the account name live in
/// UserDefaults, the API key, shared secret and session key in the Keychain.
nonisolated enum LastFMCredentialStore {
    static let enabledKey = "lastFMEnabled"
    static let usernameKey = "lastFMUsername"

    nonisolated enum Item: String, CaseIterable {
        case apiKey = "api_key"
        case sharedSecret = "shared_secret"
        case sessionKey = "session_key"
    }

    private static let service = "ch.vkugler.shelv.lastfm"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var username: String {
        get { UserDefaults.standard.string(forKey: usernameKey) ?? "" }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: usernameKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: usernameKey)
            }
        }
    }

    static func snapshot() -> LastFMCloudSnapshot {
        LastFMCloudSnapshot(
            isEnabled: isEnabled,
            username: username,
            apiKey: read(.apiKey),
            sharedSecret: read(.sharedSecret),
            sessionKey: read(.sessionKey)
        )
    }

    /// Writes a complete snapshot, e.g. one that arrived from iCloud.
    /// Returns `false` if the Keychain refused a write.
    @discardableResult
    static func apply(_ snapshot: LastFMCloudSnapshot) -> Bool {
        let stored = write(snapshot.apiKey, for: .apiKey)
            && write(snapshot.sharedSecret, for: .sharedSecret)
            && write(snapshot.sessionKey, for: .sessionKey)
        guard stored else { return false }
        isEnabled = snapshot.isEnabled
        username = snapshot.username
        return true
    }

    // MARK: - Keychain

    static func read(_ item: Item) -> String {
        var query = baseQuery(for: item)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    /// An empty value removes the item.
    @discardableResult
    static func write(_ value: String, for item: Item) -> Bool {
        let query = baseQuery(for: item)
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(for item: Item) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: item.rawValue,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}
