import SwiftUI
import Combine

@MainActor
class DiscoverViewModel: ObservableObject {
    @Published var recentlyAdded: [Album] = []
    @Published var recentlyPlayed: [Album] = []
    @Published var frequentlyPlayed: [Album] = []
    @Published var randomAlbums: [Album] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared
    private static let shelfSize = 20
    private var loadGeneration = 0

    @discardableResult
    func load(force: Bool = false) async -> Bool {
        guard !isLoading else { return !recentlyAdded.isEmpty || !recentlyPlayed.isEmpty || !frequentlyPlayed.isEmpty || !randomAlbums.isEmpty }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        async let newest   = api.getAlbumList(type: .newest,         size: Self.shelfSize)
        async let recent   = api.getAlbumList(type: .recentlyPlayed, size: Self.shelfSize)
        async let frequent = api.getAlbumList(type: .frequent,       size: Self.shelfSize)
        async let random   = api.getAlbumList(type: .random,         size: Self.shelfSize)
        do {
            let loadedNewest = try await newest
            let loadedRecent = try await recent
            let loadedFrequent = try await frequent
            let loadedRandom = try await random
            guard loadGeneration == generation else { return false }
            recentlyAdded    = loadedNewest
            recentlyPlayed   = loadedRecent
            frequentlyPlayed = loadedFrequent
            randomAlbums     = loadedRandom
            return true
        } catch {
            guard loadGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reset() {
        loadGeneration += 1
        recentlyAdded = []
        recentlyPlayed = []
        frequentlyPlayed = []
        randomAlbums = []
        errorMessage = nil
        isLoading = false
    }

    func stopLoadingForConnectionRecovery() {
        loadGeneration += 1
        errorMessage = nil
        isLoading = false
    }

    func refreshRandom() async {
        do {
            randomAlbums = try await api.getAlbumList(type: .random, size: Self.shelfSize)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playMixNewest() async {
        do {
            let songs = try await api.getNewestSongs()
            player.playShuffled(songs: songs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playMixFrequent() async {
        do {
            let songs = try await frequentMixSongs()
            player.playShuffled(songs: songs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playMixRandom() async {
        do {
            let songs = try await api.getRandomSongs(size: 500)
            player.playShuffled(songs: songs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playMixRecent() async {
        do {
            let songs = try await recentMixSongs()
            player.playShuffled(songs: songs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func frequentMixSongs() async throws -> [Song] {
        if UserDefaults.standard.bool(forKey: "mixUseDatabase"),
           let serverId = AppState.shared.serverStore.activeServer?.stableId,
           !serverId.isEmpty,
           await PlayLogService.shared.distinctSongCount(serverId: serverId) >= 50 {
            let counts = await PlayLogService.shared.topSongs(
                serverId: serverId, from: .distantPast, to: Date(), limit: 50)
            if !counts.isEmpty {
                return try await api.getSongsOrdered(ids: counts.map(\.songId))
            }
        }
        return try await api.frequentMixFallbackSongs()
    }

    private func recentMixSongs() async throws -> [Song] {
        if UserDefaults.standard.bool(forKey: "mixUseDatabase"),
           let serverId = AppState.shared.serverStore.activeServer?.stableId,
           !serverId.isEmpty,
           await PlayLogService.shared.distinctSongCount(serverId: serverId) >= 50 {
            let ids = await PlayLogService.shared.recentUniqueSongIds(serverId: serverId, limit: 50)
            if !ids.isEmpty {
                return try await api.getSongsOrdered(ids: ids)
            }
        }
        return try await api.getRecentSongs(limit: 50)
    }
}
