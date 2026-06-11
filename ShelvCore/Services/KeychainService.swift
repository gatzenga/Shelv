import Foundation
import Security

enum KeychainService {
    static func save(password: String, for serverID: UUID) {
        let key = "shelv_server_\(serverID.uuidString)"
        let data = Data(password.utf8)

        // kSecAttrAccessible kann via SecItemUpdate nicht geändert werden —
        // daher immer löschen + neu anlegen, damit AfterFirstUnlock garantiert ist.
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for serverID: UUID) -> String? {
        let key = "shelv_server_\(serverID.uuidString)"

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for serverID: UUID) {
        let key = "shelv_server_\(serverID.uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
