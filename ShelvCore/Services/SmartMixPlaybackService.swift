import Foundation

/// Canonical song selection for the smart-mix buttons and system intents.
/// Every caller still decides how to present errors and starts the returned
/// songs shuffled, but the content of each mix is shared across platforms.
nonisolated enum SmartMixPlaybackService {
    static func songs(for mix: ShortcutSmartMix) async throws -> [Song] {
        let api = SubsonicAPIService.shared
        switch mix {
        case .newest:
            return try await api.getNewestSongs()
        case .frequent:
            return try await frequentSongs(api: api)
        case .recent:
            return try await recentSongs(api: api)
        case .shuffleAll:
            return try await api.getRandomSongs(size: 500)
        }
    }

    /// Last.fm when the Mixes option is on and connected, because it also knows
    /// plays from other players. Otherwise, or when too few scrobbles match the
    /// library, the server's own play counts.
    private static func frequentSongs(api: SubsonicAPIService) async throws -> [Song] {
        if let songs = await LastFMService.shared.topSongs() {
            return songs
        }
        return try await navidromeFallback("Frequently Played") {
            try await api.frequentMixFallbackSongs()
        }
    }

    private static func recentSongs(api: SubsonicAPIService) async throws -> [Song] {
        if let songs = await LastFMService.shared.recentSongs() {
            return songs
        }
        return try await navidromeFallback("Recently Played") {
            try await api.getRecentlyPlayedSongs(limit: 50)
        }
    }

    /// Logs the server fallback only for listeners who use Last.fm, so the
    /// log shows where a mix came from when Last.fm could not deliver it.
    private static func navidromeFallback(
        _ label: String,
        _ load: () async throws -> [Song]
    ) async throws -> [Song] {
        guard LastFMCredentialStore.isEnabled, LastFMCredentialStore.mixesEnabled else { return try await load() }
        do {
            let songs = try await load()
            ExternalServicesLog.success("\(label): \(songs.count) songs from Navidrome")
            return songs
        } catch {
            ExternalServicesLog.failure("\(label): Navidrome request failed")
            throw error
        }
    }
}
