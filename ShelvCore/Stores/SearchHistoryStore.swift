import Foundation

enum SearchHistoryStore {
    static let maximumEntryCount = 20

    private static let storageKeyPrefix = "shelv_search_history_v1_"

    static func entries(for serverID: UUID?) -> [String] {
        guard let serverID else { return [] }
        return Array(
            (UserDefaults.standard.stringArray(forKey: storageKey(for: serverID)) ?? [])
                .prefix(maximumEntryCount)
        )
    }

    @discardableResult
    static func record(_ rawQuery: String, for serverID: UUID?) -> [String] {
        guard let serverID else { return [] }
        let query = normalized(rawQuery)
        guard !query.isEmpty else { return entries(for: serverID) }

        var history = entries(for: serverID)
        history.removeAll {
            $0.localizedCaseInsensitiveCompare(query) == .orderedSame
        }
        history.insert(query, at: 0)
        if history.count > maximumEntryCount {
            history.removeLast(history.count - maximumEntryCount)
        }
        UserDefaults.standard.set(history, forKey: storageKey(for: serverID))
        return history
    }

    @discardableResult
    static func clear(for serverID: UUID?) -> [String] {
        guard let serverID else { return [] }
        UserDefaults.standard.removeObject(forKey: storageKey(for: serverID))
        return []
    }

    private static func normalized(_ query: String) -> String {
        query
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func storageKey(for serverID: UUID) -> String {
        storageKeyPrefix + serverID.uuidString
    }
}
