import SwiftUI
import Combine
import OSLog

private let discoverModelLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ch.vkugler.Shelv",
    category: "DiscoverStartup"
)

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
    private var activeLoadTask: Task<Bool, Never>?

    private var hasDiscoverContent: Bool {
        !recentlyAdded.isEmpty || !recentlyPlayed.isEmpty || !frequentlyPlayed.isEmpty || !randomAlbums.isEmpty
    }

    @discardableResult
    func load(force: Bool = false) async -> Bool {
        if !force && hasLoadedDiscoverContent {
            discoverModelLogger.debug("Load reused completed content")
            return true
        }

        if let activeLoadTask {
            discoverModelLogger.info("Load joined active request")
            return await activeLoadTask.value
        }

        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        discoverModelLogger.info("Load started generation=\(generation)")

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performLoad(generation: generation)
        }
        activeLoadTask = task
        let didLoad = await task.value
        if loadGeneration == generation {
            activeLoadTask = nil
            isLoading = false
        }
        discoverModelLogger.info("Load finished generation=\(generation) success=\(didLoad)")
        return didLoad
    }

    private func performLoad(generation: Int) async -> Bool {
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
            discoverModelLogger.info(
                "Shelves loaded newest=\(loadedNewest.count) recent=\(loadedRecent.count) frequent=\(loadedFrequent.count) random=\(loadedRandom.count)"
            )
            return true
        } catch {
            guard loadGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            let nsError = error as NSError
            discoverModelLogger.error(
                "Shelf load failed generation=\(generation) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) taskCancelled=\(Task.isCancelled)"
            )
            return false
        }
    }

    func reset() {
        discoverModelLogger.info("Load reset active=\(self.activeLoadTask != nil)")
        activeLoadTask?.cancel()
        activeLoadTask = nil
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
        discoverModelLogger.info("Load stopped for connection recovery active=\(self.activeLoadTask != nil)")
        activeLoadTask?.cancel()
        activeLoadTask = nil
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
