import Foundation
import SwiftUI
import Combine

nonisolated struct LyricsDownloadActivitySnapshot: Equatable, Sendable {
    let isDownloading: Bool
    let fetched: Int
    let total: Int

    static let idle = LyricsDownloadActivitySnapshot(
        isDownloading: false,
        fetched: 0,
        total: 0
    )
}

@MainActor
final class LyricsDownloadActivityStore: ObservableObject {
    static let shared = LyricsDownloadActivityStore()

    @Published private(set) var snapshot: LyricsDownloadActivitySnapshot = .idle

    private init() {}

    func begin() {
        set(.init(isDownloading: true, fetched: 0, total: 0))
    }

    func setPlannedTotal(_ total: Int) {
        set(.init(isDownloading: total > 0, fetched: 0, total: total))
    }

    func update(completed: Int, total: Int) {
        set(.init(
            isDownloading: completed < total,
            fetched: completed,
            total: total
        ))
    }

    func reset() {
        set(.idle)
    }

    private func set(_ newSnapshot: LyricsDownloadActivitySnapshot) {
        guard snapshot != newSnapshot else { return }
        snapshot = newSnapshot
    }
}

@MainActor
class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    @Published var currentLyrics: LyricsRecord?
    @Published var isLoadingLyrics: Bool = false
    @Published var dbSize: String = "—"
    @Published var fetchedCount: Int = 0

    private var loadTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: UUID?
    private var currentDownloadServerId: String?
    private var progressCancellable: AnyCancellable?
    private let downloadActivity = LyricsDownloadActivityStore.shared

    // MARK: - Setup

    func setup() async {
        await LyricsService.shared.setup()
        await LyricsBackgroundService.shared.setup()
        refreshDbSize()
        subscribeToBackgroundProgress()
    }

    private func subscribeToBackgroundProgress() {
        progressCancellable = LyricsBackgroundService.shared.progressUpdates
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] update in
                guard let self else { return }
                if let update {
                    self.downloadActivity.update(
                        completed: update.completed,
                        total: update.total
                    )
                } else {
                    self.downloadActivity.reset()
                    if let sid = self.currentDownloadServerId {
                        Task { await self.refreshFetchedCount(serverId: sid) }
                    }
                    self.refreshDbSize()
                }
            }
    }

    // MARK: - Load lyrics for current song

    func loadLyrics(for song: Song, serverId: String) {
        loadTask?.cancel()
        currentLyrics = nil
        isLoadingLyrics = true
        loadTask = Task {
            let record = await LyricsService.shared.fetchAndSave(song: song, serverId: serverId)
            guard !Task.isCancelled else { return }
            currentLyrics = record
            isLoadingLyrics = false
        }
    }

    // MARK: - Bulk download

    func startBulkDownload(serverId: String) {
        guard !downloadActivity.snapshot.isDownloading else { return }
        downloadActivity.begin()
        currentDownloadServerId = serverId
        let generation = UUID()
        downloadGeneration = generation

        downloadTask = Task.detached(priority: .utility) { [serverId, generation] in
            defer {
                Task { @MainActor in
                    let store = LyricsStore.shared
                    guard store.downloadGeneration == generation else { return }
                    store.refreshDbSize()
                    if let sid = store.currentDownloadServerId {
                        await store.refreshFetchedCount(serverId: sid)
                        guard store.downloadGeneration == generation else { return }
                    }
                    // Safety: falls die BG-Session nichts enqueued hat (z.B. weil keine
                    // Songs vorhanden oder Task früh gecancelt), isDownloading manuell resetten
                    let running = await LyricsBackgroundService.shared.isRunning()
                    guard store.downloadGeneration == generation else { return }
                    if !running {
                        store.downloadActivity.reset()
                    }
                }
            }

            let api = SubsonicAPIService.shared
            var albums: [Album] = []
            var offset = 0
            let pageSize = 500
            while !Task.isCancelled {
                guard let page = try? await api.getAllAlbums(size: pageSize, offset: offset) else { break }
                albums.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += pageSize
            }
            if Task.isCancelled { return }

            let allSongs: [Song] = await withTaskGroup(of: [Song].self) { group -> [Song] in
                let maxConcurrent = 10
                var iterator = albums.makeIterator()
                var active = 0
                while active < maxConcurrent, let album = iterator.next() {
                    group.addTask { (try? await api.getAlbum(id: album.id))?.song ?? [] }
                    active += 1
                }
                var collected: [Song] = []
                while let songs = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return [] }
                    collected.append(contentsOf: songs)
                    if let next = iterator.next() {
                        group.addTask { (try? await api.getAlbum(id: next.id))?.song ?? [] }
                    }
                }
                return collected
            }
            if Task.isCancelled { return }

            let cachedSongIds = await LyricsService.shared.cachedSongIds(serverId: serverId)
            let songsToDownload = allSongs.filter { !cachedSongIds.contains($0.id) }
            DBErrorLog.logLyrics(
                "Bulk scan → library \(allSongs.count), local DB \(cachedSongIds.count), queue \(songsToDownload.count)"
            )

            let isCurrent = await MainActor.run {
                let store = LyricsStore.shared
                guard store.downloadGeneration == generation else { return false }
                store.downloadActivity.setPlannedTotal(songsToDownload.count)
                return true
            }
            guard isCurrent, !Task.isCancelled else { return }
            if !songsToDownload.isEmpty {
                await LyricsBackgroundService.shared.enqueueSongs(songsToDownload, serverId: serverId)
            } else {
                await MainActor.run {
                    let store = LyricsStore.shared
                    guard store.downloadGeneration == generation else { return }
                    store.downloadActivity.reset()
                }
            }
        }
    }

    func cancelBulkDownload() {
        downloadGeneration = nil
        downloadTask?.cancel()
        downloadTask = nil
        Task {
            await LyricsBackgroundService.shared.cancelAll()
        }
        downloadActivity.reset()
        if let sid = currentDownloadServerId {
            Task { await self.refreshFetchedCount(serverId: sid) }
        }
    }

    // MARK: - Reset

    func reset(serverId: String) async {
        downloadGeneration = nil
        downloadTask?.cancel()
        downloadTask = nil
        await LyricsBackgroundService.shared.cancelAll()
        await LyricsService.shared.resetAll()
        currentLyrics = nil
        downloadActivity.reset()
        fetchedCount = 0
        refreshDbSize()
    }

    // MARK: - Stats

    func refreshFetchedCount(serverId: String) async {
        let count = await LyricsService.shared.fetchedCount(serverId: serverId)
        self.fetchedCount = count
    }

    func refreshDbSize() {
        let bytes = LyricsService.diskSizeBytes()
        Task {
            let rows = await LyricsService.shared.totalRowCount()
            let text = rows == 0
                ? String(localized: "empty")
                : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            await MainActor.run { self.dbSize = text }
        }
    }
}
