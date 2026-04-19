import Foundation
import SwiftUI
import Combine

@MainActor
class LyricsStore: ObservableObject {
    @Published var currentLyrics: LyricsRecord?
    @Published var isLoadingLyrics: Bool = false
    @Published var isDownloading: Bool = false
    @Published var downloadFetched: Int = 0
    @Published var downloadTotal: Int = 0
    @Published var dbSize: String = "—"

    private var loadTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    // MARK: - Setup

    func setup() async {
        await LyricsService.shared.setup()
        refreshDbSize()
    }

    // MARK: - Load lyrics for current song

    func loadLyrics(for song: Song, serverId: String) {
        loadTask?.cancel()
        currentLyrics = nil
        isLoadingLyrics = true
        loadTask = Task {
            let record = await LyricsService.shared.fetchAndSave(song: song, serverId: serverId)
            guard !Task.isCancelled else {
                isLoadingLyrics = false
                return
            }
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

        let api = SubsonicAPIService.shared
        let svc = LyricsService.shared

        downloadTask = Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.isDownloading = false
                    self?.refreshDbSize()
                }
            }

            // Alben direkt via API holen (unabhängig vom LibraryStore-Cache)
            var albums: [Album] = []
            var offset = 0
            let pageSize = 500
            while true {
                guard !Task.isCancelled else { return }
                guard let page = try? await api.getAllAlbums(size: pageSize, offset: offset) else { break }
                albums.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += pageSize
            }
            guard !Task.isCancelled else { return }

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
                    collected.append(contentsOf: songs)
                    if let next = iterator.next() {
                        group.addTask { (try? await api.getAlbum(id: next.id))?.song ?? [] }
                    }
                }
                return collected
            }
            guard !Task.isCancelled else { return }

            let totalCount = allSongs.count
            await MainActor.run { [weak self] in self?.downloadTotal = totalCount }

            await withTaskGroup(of: Void.self) { group in
                let maxConcurrent = 20
                var iterator = allSongs.makeIterator()
                var active = 0
                while active < maxConcurrent, let song = iterator.next() {
                    group.addTask { _ = await svc.fetchAndSave(song: song, serverId: serverId) }
                    active += 1
                }
                var fetched = 0
                var lastPublished = Date.distantPast
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll(); return }
                    fetched += 1
                    let now = Date()
                    if now.timeIntervalSince(lastPublished) >= 0.1 {
                        lastPublished = now
                        let f = fetched
                        await MainActor.run { [weak self] in self?.downloadFetched = f }
                    }
                    if let next = iterator.next() {
                        group.addTask { _ = await svc.fetchAndSave(song: next, serverId: serverId) }
                    }
                }
                let finalCount = fetched
                await MainActor.run { [weak self] in self?.downloadFetched = finalCount }
            }
        }
    }

    func cancelBulkDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
    }

    // MARK: - Reset

    func reset(serverId: String) async {
        await LyricsService.shared.reset(serverId: serverId)
        currentLyrics = nil
        downloadFetched = 0
        downloadTotal = 0
        refreshDbSize()
    }

    // MARK: - Stats

    func fetchedCount(serverId: String) async -> Int {
        await LyricsService.shared.fetchedCount(serverId: serverId)
    }

    func refreshDbSize() {
        let bytes = LyricsService.diskSizeBytes()
        dbSize = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            : tr("Empty", "Leer")
    }
}
