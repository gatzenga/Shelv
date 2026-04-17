import Foundation
import Security

enum KeychainService {
    static func save(password: String, for serverID: UUID) {
        let key = "shelv_server_\(serverID.uuidString)"
        let data = Data(password.utf8)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let searchQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: key
            ]
            let updateAttrs: [CFString: Any] = [
                kSecValueData: data
            ]
            SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
        }
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
