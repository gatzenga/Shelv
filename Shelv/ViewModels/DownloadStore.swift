import Foundation
import SwiftUI
import Combine

@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var songs: [DownloadedSong] = []
    @Published private(set) var albums: [DownloadedAlbum] = []
    @Published private(set) var artists: [DownloadedArtist] = []
    @Published private(set) var favoriteSongs: [DownloadedSong] = []
    @Published private(set) var totalBytes: Int64 = 0
    private(set) var inFlightProgress: [String: Double] = [:]
    private(set) var inFlightStates: [String: DownloadState] = [:]
    nonisolated let progressPublisher = PassthroughSubject<Void, Never>()
    @Published private(set) var batchProgress: BatchProgress? = nil
    @Published private(set) var isLoading: Bool = false

    private var serverId: String = ""
    private var cancellables = Set<AnyCancellable>()
    /// Mapping artistName → coverArtId aus der Library (gefüllt vom LibraryStore)
    private var artistCoverByName: [String: String] = [:]
    private var pendingReload = false

    init() {
        DownloadService.shared.progressUpdates
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.global(qos: .userInteractive), latest: true)
            .sink { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.inFlightProgress = progress
                    self.progressPublisher.send(())
                }
            }
            .store(in: &cancellables)

        DownloadService.shared.stateUpdates
            .sink { update in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let isDl: Bool
                    if case .downloading = update.state { isDl = true } else { isDl = false }
                    if case .none = update.state {
                        self.inFlightStates.removeValue(forKey: update.key)
                    } else if case .completed = update.state {
                        self.inFlightStates.removeValue(forKey: update.key)
                    } else {
                        self.inFlightStates[update.key] = update.state
                    }
                    if !isDl { self.progressPublisher.send(()) }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .downloadsLibraryChanged)
            .sink { [weak self] _ in Task { @MainActor [weak self] in await self?.reload() } }
            .store(in: &cancellables)

        DownloadService.shared.batchUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in self?.batchProgress = progress }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .libraryArtistsLoaded)
            .sink { [weak self] note in
                guard let map = note.object as? [String: String] else { return }
                Task { @MainActor [weak self] in self?.updateArtistCovers(map) }
            }
            .store(in: &cancellables)
    }

    func setActiveServer(_ serverId: String) async {
        guard self.serverId != serverId else { return }
        self.serverId = serverId
        await reload()
    }

    func updateArtistCovers(_ map: [String: String]) {
        artistCoverByName = map
        Task { await reload() }
    }

    func reload() async {
        guard !serverId.isEmpty else {
            songs = []; albums = []; artists = []; favoriteSongs = []; totalBytes = 0
            return
        }
        guard !isLoading else { pendingReload = true; return }
        isLoading = true
        pendingReload = false
        let sid = serverId
        let records = await DownloadDatabase.shared.allRecords(serverId: sid)
        let total = await DownloadDatabase.shared.totalBytes(serverId: sid)
        let mappedSongs = records.map { $0.toDownloadedSong() }

        // Gruppieren
        let albumsGrouped = Dictionary(grouping: mappedSongs) { $0.albumId }
            .map { (albumId, group) -> DownloadedAlbum in
                let sorted = group.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
                let first = sorted.first!
                return DownloadedAlbum(
                    albumId: albumId, serverId: sid,
                    title: first.albumTitle, artistName: first.artistName,
                    artistId: first.artistId, coverArtId: first.coverArtId,
                    songs: sorted
                )
            }
            .sorted {
                if $0.artistName.lowercased() != $1.artistName.lowercased() {
                    return $0.artistName.lowercased() < $1.artistName.lowercased()
                }
                return $0.title.lowercased() < $1.title.lowercased()
            }

        // Künstler — Gruppieren über artistName (artistId kann nil sein)
        let artistsGrouped = Dictionary(grouping: albumsGrouped) { $0.artistName }
            .map { (artistName, albums) -> DownloadedArtist in
                let first = albums.first!
                let cover = artistCoverByName[artistName] ?? first.coverArtId
                return DownloadedArtist(
                    artistId: first.artistId ?? "name:\(artistName)",
                    serverId: sid,
                    name: artistName,
                    coverArtId: cover,
                    albums: albums
                )
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        songs = mappedSongs
        albums = albumsGrouped
        artists = artistsGrouped
        favoriteSongs = mappedSongs.filter { $0.isFavorite }
        totalBytes = total

        var paths: [String: String] = [:]
        for song in mappedSongs {
            paths[LocalDownloadIndex.key(songId: song.songId, serverId: song.serverId)] = song.filePath
        }
        LocalDownloadIndex.shared.update(paths: paths)

        isLoading = false
        if pendingReload {
            pendingReload = false
            await reload()
        }
    }

    // MARK: - Lookups

    func isDownloaded(songId: String) -> Bool {
        songs.contains(where: { $0.songId == songId })
    }

    func downloadState(songId: String) -> DownloadState {
        let key = DownloadService.key(songId: songId, serverId: serverId)
        if let s = inFlightStates[key] { return s }
        if let p = inFlightProgress[key] { return .downloading(progress: p) }
        return isDownloaded(songId: songId) ? .completed : .none
    }

    func progress(songId: String) -> Double? {
        let key = DownloadService.key(songId: songId, serverId: serverId)
        return inFlightProgress[key]
    }

    func localURL(for songId: String) -> URL? {
        guard let record = songs.first(where: { $0.songId == songId }) else { return nil }
        let url = record.fileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func coverURL(for songId: String) -> URL? {
        guard let record = songs.first(where: { $0.songId == songId }) else { return nil }
        let path = DownloadService.coverPath(forFilePath: record.filePath)
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func albumDownloadStatus(albumId: String, totalSongs: Int) -> AlbumDownloadStatus {
        let downloaded = songs.filter { $0.albumId == albumId }.count
        if downloaded == 0 { return .none }
        if downloaded >= totalSongs { return .complete }
        return .partial(downloaded: downloaded, total: totalSongs)
    }

    // MARK: - Actions (Convenience)

    func enqueueSongs(_ songs: [Song]) {
        let sid = serverId
        Task { await DownloadService.shared.enqueue(songs: songs, serverId: sid) }
    }

    func enqueueAlbum(_ album: Album) {
        let sid = serverId
        Task { await DownloadService.shared.enqueueAlbum(album: album, serverId: sid) }
    }

    func enqueueArtist(_ artist: Artist) {
        let sid = serverId
        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
    }

    func deleteSong(_ songId: String) {
        let sid = serverId
        Task { await DownloadService.shared.delete(songId: songId, serverId: sid) }
    }

    func deleteAlbum(_ albumId: String) {
        let sid = serverId
        Task { await DownloadService.shared.deleteAlbum(albumId: albumId, serverId: sid) }
    }

    func deleteArtist(_ artistId: String) {
        let sid = serverId
        Task { await DownloadService.shared.deleteArtist(artistId: artistId, serverId: sid) }
    }

    func deleteAll() {
        Task { await DownloadService.shared.deleteAll() }
    }

    // MARK: - Stats

    /// `albumSongCounts` = Mapping albumId → songCount aus Library (Subsonic).
    /// `artistAlbumIds`  = Mapping artistId → Set aller Album-IDs dieses Künstlers aus Library.
    /// Alben/Künstler werden nur gezählt wenn sie **vollständig** heruntergeladen sind.
    func computeStats(albumSongCounts: [String: Int] = [:],
                      artistAlbumIds: [String: Set<String>] = [:]) async -> DownloadStorageStats {
        let sid = serverId
        let top = await DownloadDatabase.shared.topArtistsByBytes(serverId: sid, limit: 5)
        let free: Int64? = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage

        let downloadedByAlbum = Dictionary(grouping: songs) { $0.albumId }
            .mapValues { $0.count }

        let completeAlbumIds = Set(downloadedByAlbum.compactMap { (albumId, count) -> String? in
            guard let total = albumSongCounts[albumId], total > 0, count >= total else { return nil }
            return albumId
        })

        let completeArtists = artistAlbumIds.filter { (_, albumIds) in
            !albumIds.isEmpty && albumIds.allSatisfy { completeAlbumIds.contains($0) }
        }

        return DownloadStorageStats(
            totalBytes: totalBytes,
            songCount: songs.count,
            albumCount: completeAlbumIds.count,
            artistCount: completeArtists.count,
            topArtists: top,
            freeDiskBytes: free
        )
    }
}

enum AlbumDownloadStatus: Equatable {
    case none
    case partial(downloaded: Int, total: Int)
    case complete
}
