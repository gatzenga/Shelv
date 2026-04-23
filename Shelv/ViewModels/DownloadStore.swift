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

    private var songById: [String: DownloadedSong] = [:]
    private var recordsByAlbumId: [String: [DownloadedSong]] = [:]

    private var serverId: String = ""
    private var cancellables = Set<AnyCancellable>()
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
            songById = [:]; recordsByAlbumId = [:]
            DownloadStatusCache.shared.rebuild(albumIds: [])
            return
        }
        guard !isLoading else { pendingReload = true; return }
        isLoading = true
        pendingReload = false
        let sid = serverId
        let records = await DownloadDatabase.shared.allRecords(serverId: sid)
        let total = await DownloadDatabase.shared.totalBytes(serverId: sid)
        let mappedSongs = records.map { $0.toDownloadedSong() }

        var newSongById: [String: DownloadedSong] = [:]
        var newRecordsByAlbumId: [String: [DownloadedSong]] = [:]
        for song in mappedSongs {
            newSongById[song.songId] = song
            newRecordsByAlbumId[song.albumId, default: []].append(song)
        }
        for key in newRecordsByAlbumId.keys {
            newRecordsByAlbumId[key]?.sort { ($0.disc ?? 0, $0.track ?? 0) < ($1.disc ?? 0, $1.track ?? 0) }
        }
        songById = newSongById
        recordsByAlbumId = newRecordsByAlbumId

        let albumsGrouped = newRecordsByAlbumId
            .map { (albumId, group) -> DownloadedAlbum in
                let first = group.first!
                return DownloadedAlbum(
                    albumId: albumId, serverId: sid,
                    title: first.albumTitle, artistName: first.artistName,
                    artistId: first.artistId, coverArtId: first.coverArtId,
                    songs: group
                )
            }
            .sorted {
                if $0.artistName.lowercased() != $1.artistName.lowercased() {
                    return $0.artistName.lowercased() < $1.artistName.lowercased()
                }
                return $0.title.lowercased() < $1.title.lowercased()
            }

        let artistsGrouped = Dictionary(grouping: albumsGrouped) { $0.artistName }
            .map { (artistName, albumsList) -> DownloadedArtist in
                let first = albumsList.first!
                let cover = first.songs.first?.artistCoverArtId ?? artistCoverByName[artistName] ?? first.coverArtId
                return DownloadedArtist(
                    artistId: first.artistId ?? "name:\(artistName)",
                    serverId: sid,
                    name: artistName,
                    coverArtId: cover,
                    albums: albumsList
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
        let artPaths = await Task.detached(priority: .utility) { () -> [String: String] in
            var dict: [String: String] = [:]
            for song in mappedSongs {
                if let artId = song.coverArtId {
                    let p = DownloadService.coverPath(forFilePath: song.filePath)
                    if FileManager.default.fileExists(atPath: p) { dict[artId] = p }
                }
                if let artId = song.artistCoverArtId {
                    let p = DownloadService.artistCoverPath(serverId: song.serverId, artId: artId)
                    if FileManager.default.fileExists(atPath: p) { dict[artId] = p }
                }
            }
            return dict
        }.value
        LocalArtworkIndex.shared.update(paths: artPaths)
        DownloadStatusCache.shared.rebuild(albumIds: Set(newRecordsByAlbumId.keys))

        isLoading = false
        if pendingReload {
            pendingReload = false
            await reload()
        }
    }

    // MARK: - Incremental Mutations

    func insertRecord(_ record: DownloadRecord) {
        guard record.serverId == serverId else { return }
        if isLoading { pendingReload = true; return }
        let song = record.toDownloadedSong()
        let albumId = song.albumId
        let artistName = song.artistName

        if let old = songById[song.songId] { totalBytes -= old.bytes }
        songById[song.songId] = song
        totalBytes += song.bytes

        if var albumSongs = recordsByAlbumId[albumId] {
            if let idx = albumSongs.firstIndex(where: { $0.songId == song.songId }) {
                albumSongs[idx] = song
            } else {
                albumSongs.append(song)
            }
            albumSongs.sort { ($0.disc ?? 0, $0.track ?? 0) < ($1.disc ?? 0, $1.track ?? 0) }
            recordsByAlbumId[albumId] = albumSongs
        } else {
            recordsByAlbumId[albumId] = [song]
        }

        if let idx = songs.firstIndex(where: { $0.songId == song.songId }) {
            songs[idx] = song
        } else {
            songs.append(song)
        }

        if song.isFavorite {
            if let idx = favoriteSongs.firstIndex(where: { $0.songId == song.songId }) {
                favoriteSongs[idx] = song
            } else {
                favoriteSongs.append(song)
            }
        } else {
            favoriteSongs.removeAll { $0.songId == song.songId }
        }

        let updatedAlbum = DownloadedAlbum(
            albumId: albumId, serverId: serverId,
            title: song.albumTitle, artistName: artistName,
            artistId: song.artistId, coverArtId: song.coverArtId,
            songs: recordsByAlbumId[albumId]!
        )
        let isNewAlbum: Bool
        if let albumIdx = albums.firstIndex(where: { $0.albumId == albumId }) {
            albums[albumIdx] = updatedAlbum
            isNewAlbum = false
        } else {
            let artistLower = artistName.lowercased()
            let albumLower = song.albumTitle.lowercased()
            let insertIdx = albums.firstIndex { e in
                let ea = e.artistName.lowercased()
                if ea != artistLower { return ea > artistLower }
                return e.title.lowercased() > albumLower
            } ?? albums.endIndex
            albums.insert(updatedAlbum, at: insertIdx)
            isNewAlbum = true
            DownloadStatusCache.shared.addAlbum(albumId)
        }

        if let artistIdx = artists.firstIndex(where: { $0.name == artistName }) {
            let artistAlbums = albums.filter { $0.artistName == artistName }
            let old = artists[artistIdx]
            artists[artistIdx] = DownloadedArtist(
                artistId: old.artistId, serverId: old.serverId,
                name: old.name, coverArtId: old.coverArtId,
                albums: artistAlbums
            )
        } else if isNewAlbum {
            let artistAlbums = albums.filter { $0.artistName == artistName }
            let cover = song.artistCoverArtId ?? artistCoverByName[artistName] ?? song.coverArtId
            let newArtist = DownloadedArtist(
                artistId: song.artistId ?? "name:\(artistName)",
                serverId: serverId,
                name: artistName,
                coverArtId: cover,
                albums: artistAlbums
            )
            let insertIdx = artists.firstIndex { $0.name.lowercased() > artistName.lowercased() } ?? artists.endIndex
            artists.insert(newArtist, at: insertIdx)
        }

        LocalDownloadIndex.shared.setPath(songId: song.songId, serverId: song.serverId, path: song.filePath)
        if let artId = song.coverArtId {
            let p = DownloadService.coverPath(forFilePath: song.filePath)
            if FileManager.default.fileExists(atPath: p) { LocalArtworkIndex.shared.set(artId: artId, path: p) }
        }
        if let artId = song.artistCoverArtId {
            let p = DownloadService.artistCoverPath(serverId: song.serverId, artId: artId)
            if FileManager.default.fileExists(atPath: p) { LocalArtworkIndex.shared.set(artId: artId, path: p) }
        }
    }

    func removeRecord(songId: String) {
        if isLoading { pendingReload = true; return }
        guard let song = songById[songId] else { return }
        let albumId = song.albumId
        let artistName = song.artistName
        let songServerId = song.serverId

        songById.removeValue(forKey: songId)
        totalBytes -= song.bytes

        recordsByAlbumId[albumId]?.removeAll { $0.songId == songId }
        let albumNowEmpty = recordsByAlbumId[albumId]?.isEmpty ?? true
        if albumNowEmpty { recordsByAlbumId.removeValue(forKey: albumId) }

        songs.removeAll { $0.songId == songId }
        favoriteSongs.removeAll { $0.songId == songId }

        if let albumIdx = albums.firstIndex(where: { $0.albumId == albumId }) {
            if albumNowEmpty {
                albums.remove(at: albumIdx)
                DownloadStatusCache.shared.removeAlbum(albumId)
            } else {
                let old = albums[albumIdx]
                albums[albumIdx] = DownloadedAlbum(
                    albumId: old.albumId, serverId: old.serverId,
                    title: old.title, artistName: old.artistName,
                    artistId: old.artistId, coverArtId: old.coverArtId,
                    songs: recordsByAlbumId[albumId]!
                )
            }
        }

        if let artistIdx = artists.firstIndex(where: { $0.name == artistName }) {
            let remainingAlbums = albums.filter { $0.artistName == artistName }
            if remainingAlbums.isEmpty {
                artists.remove(at: artistIdx)
            } else {
                let old = artists[artistIdx]
                artists[artistIdx] = DownloadedArtist(
                    artistId: old.artistId, serverId: old.serverId,
                    name: old.name, coverArtId: old.coverArtId,
                    albums: remainingAlbums
                )
            }
        }

        LocalDownloadIndex.shared.setPath(songId: songId, serverId: songServerId, path: nil)
    }

    // MARK: - Lookups

    func isDownloaded(songId: String) -> Bool {
        songById[songId] != nil
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
        guard let record = songById[songId] else { return nil }
        let url = record.fileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func coverURL(for songId: String) -> URL? {
        guard let record = songById[songId] else { return nil }
        let path = DownloadService.coverPath(forFilePath: record.filePath)
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func albumDownloadStatus(albumId: String, totalSongs: Int) -> AlbumDownloadStatus {
        let downloaded = recordsByAlbumId[albumId]?.count ?? 0
        if downloaded == 0 { return .none }
        if downloaded >= totalSongs { return .complete }
        return .partial(downloaded: downloaded, total: totalSongs)
    }

    // MARK: - Actions

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

    func computeStats(albumSongCounts: [String: Int] = [:],
                      artistAlbumIds: [String: Set<String>] = [:]) async -> DownloadStorageStats {
        let sid = serverId
        let top = await DownloadDatabase.shared.topArtistsByBytes(serverId: sid, limit: 5)
        let free: Int64? = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage

        let completeAlbumIds = Set(recordsByAlbumId.compactMap { (albumId, albumSongs) -> String? in
            guard let total = albumSongCounts[albumId], total > 0, albumSongs.count >= total else { return nil }
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
