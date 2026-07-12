import Foundation

/// Canonical song selection for the smart-mix buttons and system intents.
/// Every caller still decides how to present errors and starts the returned
/// songs shuffled, but the content of each mix is shared across platforms.
nonisolated enum SmartMixPlaybackService {
    static func songs(
        for mix: ShortcutSmartMix,
        storageServerID: String? = nil
    ) async throws -> [Song] {
        let api = SubsonicAPIService.shared
        switch mix {
        case .newest:
            return try await api.getNewestSongs()
        case .frequent:
            return try await frequentSongs(api: api, storageServerID: storageServerID)
        case .recent:
            return try await recentSongs(api: api, storageServerID: storageServerID)
        case .shuffleAll:
            return try await api.getRandomSongs(size: 500)
        }
    }

    private static func frequentSongs(
        api: SubsonicAPIService,
        storageServerID: String?
    ) async throws -> [Song] {
        if UserDefaults.standard.bool(forKey: "mixUseDatabase"),
           let serverID = resolvedStorageServerID(storageServerID, api: api),
           await PlayLogService.shared.distinctSongCount(serverId: serverID) >= 50 {
            let counts = await PlayLogService.shared.topSongs(
                serverId: serverID,
                from: .distantPast,
                to: Date(),
                limit: 50
            )
            if !counts.isEmpty {
                return try await api.getSongsOrdered(ids: counts.map(\.songId))
            }
        }
        return try await api.frequentMixFallbackSongs()
    }

    private static func recentSongs(
        api: SubsonicAPIService,
        storageServerID: String?
    ) async throws -> [Song] {
        if UserDefaults.standard.bool(forKey: "mixUseDatabase"),
           let serverID = resolvedStorageServerID(storageServerID, api: api),
           await PlayLogService.shared.distinctSongCount(serverId: serverID) >= 50 {
            let ids = await PlayLogService.shared.recentUniqueSongIds(
                serverId: serverID,
                limit: 50
            )
            if !ids.isEmpty {
                return try await api.getSongsOrdered(ids: ids)
            }
        }
        return try await api.getRecentSongs(limit: 50)
    }

    private static func resolvedStorageServerID(
        _ explicitID: String?,
        api: SubsonicAPIService
    ) -> String? {
        if let explicitID, !explicitID.isEmpty { return explicitID }
        guard let server = api.activeServer else { return nil }
        return server.stableId.isEmpty ? server.id.uuidString : server.stableId
    }
}
