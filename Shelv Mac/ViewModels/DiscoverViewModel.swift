import SwiftUI
import Combine

@MainActor
class DiscoverViewModel: ObservableObject {
    static let shared = DiscoverViewModel()

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
    private var hasLoadedDiscoverContent = false

    private var hasDiscoverContent: Bool {
        !recentlyAdded.isEmpty || !recentlyPlayed.isEmpty || !frequentlyPlayed.isEmpty || !randomAlbums.isEmpty
    }

    @discardableResult
    func load(force: Bool = false) async -> Bool {
        if !force && hasLoadedDiscoverContent {
            return true
        }

        guard !isLoading else { return hasLoadedDiscoverContent || hasDiscoverContent }
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
            hasLoadedDiscoverContent = true
            return true
        } catch {
            guard loadGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reset() {
        loadGeneration += 1
        hasLoadedDiscoverContent = false
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
        await playMix(.newest)
    }

    func playMixFrequent() async {
        await playMix(.frequent)
    }

    func playMixRandom() async {
        await playMix(.shuffleAll)
    }

    func playMixRecent() async {
        await playMix(.recent)
    }

    private func playMix(_ mix: ShortcutSmartMix) async {
        do {
            let songs = try await SmartMixPlaybackService.songs(for: mix)
            player.playShuffled(songs: songs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
