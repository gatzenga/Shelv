import Foundation
import SwiftUI
import Combine

@MainActor
class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    @Published var currentLyrics: LyricsRecord?
    @Published var isLoadingLyrics: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadFetched: Int = 0
    @Published var downloadTotal: Int = 0
    @Published var dbSize: String = "—"
    @Published var fetchedCount: Int = 0

    private var loadTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var progressPollTask: Task<Void, Never>?
    private var currentDownloadServerId: String?
    private var progressCancellable: AnyCancellable?

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
                    self.downloadFetched = update.completed
                    self.downloadTotal = update.total
                    self.isDownloading = update.completed < update.total
                } else {
                    self.downloadFetched = 0
                    self.downloadTotal = 0
                    self.isDownloading = false
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
        guard !isDownloading else { return }
        isDownloading = true
        downloadFetched = 0
        downloadTotal = 0
        currentDownloadServerId = serverId
        startProgressPolling()

        downloadTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.refreshDbSize()
                    if let sid = self?.currentDownloadServerId {
                        await self?.refreshFetchedCount(serverId: sid)
                    }
                    // Safety: falls die BG-Session nichts enqueued hat (z.B. weil keine
                    // Songs vorhanden oder Task früh gecancelt), isDownloading manuell resetten
                    let running = await LyricsBackgroundService.shared.isRunning()
                    if !running {
                        self?.isDownloading = false
                        if self?.downloadTotal == 0 {
                            self?.downloadFetched = 0
                            self?.downloadTotal = 0
                        }
                        self?.stopProgressPolling()
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

            await MainActor.run { [weak self] in
                self?.downloadTotal = songsToDownload.count
            }
            if !songsToDownload.isEmpty {
                await LyricsBackgroundService.shared.enqueueSongs(songsToDownload, serverId: serverId)
            } else {
                await MainActor.run { [weak self] in
                    self?.isDownloading = false
                    self?.stopProgressPolling()
                }
            }
        }
    }

    private func startProgressPolling() {
        progressPollTask?.cancel()
        progressPollTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await LyricsBackgroundService.shared.progressSnapshot()
                let running = await LyricsBackgroundService.shared.isRunning()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let snapshot {
                        self.downloadFetched = snapshot.completed
                        self.downloadTotal = snapshot.total
                    }
                    if !running, self.downloadTotal > 0, self.downloadFetched >= self.downloadTotal {
                        self.isDownloading = false
                    }
                }
                if await MainActor.run(body: { [weak self] in self?.isDownloading == false }) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopProgressPolling() {
        progressPollTask?.cancel()
        progressPollTask = nil
    }

    func cancelBulkDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        stopProgressPolling()
        Task {
            await LyricsBackgroundService.shared.cancelAll()
        }
        isDownloading = false
        downloadFetched = 0
        downloadTotal = 0
        if let sid = currentDownloadServerId {
            Task { await self.refreshFetchedCount(serverId: sid) }
        }
    }

    // MARK: - Reset

    func reset(serverId: String) async {
        downloadTask?.cancel()
        downloadTask = nil
        stopProgressPolling()
        await LyricsBackgroundService.shared.cancelAll()
        await LyricsService.shared.resetAll()
        currentLyrics = nil
        downloadFetched = 0
        downloadTotal = 0
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
