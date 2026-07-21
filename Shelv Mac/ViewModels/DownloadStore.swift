import Foundation
import SwiftUI
@preconcurrency import Combine

@MainActor
final class DownloadActivityStore: ObservableObject {
    static let shared = DownloadActivityStore()

    @Published private(set) var batchProgress: BatchProgress?

    private init() {}

    func update(_ progress: BatchProgress?) {
        guard batchProgress != progress else { return }
        batchProgress = progress
    }
}

@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    private(set) var songs: [DownloadedSong] = []
    private(set) var albums: [DownloadedAlbum] = []
    private(set) var artists: [DownloadedArtist] = []
    private(set) var favoriteSongs: [DownloadedSong] = []
    @Published private(set) var downloadedPlaylistIds: Set<String> = []
    private(set) var playlistSongIds: [String: [String]] = [:]
    private(set) var totalBytes: Int64 = 0
    private(set) var inFlightProgress: [String: Double] = [:]
    private(set) var inFlightStates: [String: DownloadState] = [:]
    nonisolated(unsafe) let progressPublisher = PassthroughSubject<Set<String>, Never>()
    nonisolated(unsafe) let catalogPublisher = PassthroughSubject<Void, Never>()
    @Published private(set) var isLoading: Bool = false

    // Internal O(1) indices — not @Published, kept in sync with the published arrays
    private var songById: [String: DownloadedSong] = [:]
    private var songIndexById: [String: Int] = [:]
    private var recordsByAlbumId: [String: [DownloadedSong]] = [:]
    private var catalogUIState: DownloadUIStateSnapshot = .empty

    private var serverId: String = ""
    private var cancellables = Set<AnyCancellable>()
    private var artistCoverByName: [String: String] = [:]
    private var pendingReload = false
    private var protectedPlaylistIds: Set<String> = []
    private var pendingInserts: [DownloadRecord] = []
    private var flushTask: Task<Void, Never>?
    private var catalogRevision: UInt64 = 0
    private var isFlushingCatalog = false
    private var isDeletingAll = false

    init() {
        DownloadService.shared.progressUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self else { return }
                let oldProgress = self.inFlightProgress
                let changedKeys = Set(oldProgress.keys)
                    .union(progress.keys)
                    .filter { oldProgress[$0] != progress[$0] }
                guard !changedKeys.isEmpty else { return }
                self.inFlightProgress = progress
                self.publishStatusChanges(forKeys: changedKeys)
            }
            .store(in: &cancellables)

        DownloadService.shared.stateUpdates
            .collect(.byTimeOrCount(DispatchQueue.global(qos: .utility), .milliseconds(50), 500))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updates in
                guard let self else { return }
                var changedKeys: Set<String> = []
                for update in updates {
                    var didChange = false
                    if case .none = update.state {
                        didChange = self.inFlightStates.removeValue(forKey: update.key) != nil
                        didChange = self.inFlightProgress.removeValue(forKey: update.key) != nil || didChange
                    } else if case .completed = update.state {
                        didChange = self.inFlightStates.removeValue(forKey: update.key) != nil
                        didChange = self.inFlightProgress.removeValue(forKey: update.key) != nil || didChange
                    } else {
                        if self.inFlightStates[update.key] != update.state {
                            self.inFlightStates[update.key] = update.state
                            didChange = true
                        }
                    }
                    if didChange { changedKeys.insert(update.key) }
                }
                self.publishStatusChanges(forKeys: changedKeys)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .downloadsLibraryChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor [weak self] in await self?.reload() } }
            .store(in: &cancellables)

        DownloadService.shared.batchUpdates
            .receive(on: DispatchQueue.main)
            .sink { progress in DownloadActivityStore.shared.update(progress) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .libraryArtistsLoaded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let map = note.object as? [String: String] else { return }
                Task { @MainActor [weak self] in self?.updateArtistCovers(map) }
            }
            .store(in: &cancellables)
    }

    private func activeSongId(forKey key: String) -> String? {
        guard !serverId.isEmpty else { return nil }
        let prefix = "\(serverId)::"
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }

    private func publishStatusChanges(forKeys keys: Set<String>) {
        let songIDs = Set(keys.compactMap(activeSongId(forKey:)))
        guard !songIDs.isEmpty else { return }
        progressPublisher.send(songIDs)
    }

    private var currentCatalogSnapshot: DownloadCatalogSnapshot {
        DownloadCatalogSnapshot(
            songs: songs,
            songIndexById: songIndexById,
            songById: songById,
            recordsByAlbumId: recordsByAlbumId,
            albums: albums,
            artists: artists,
            favoriteSongs: favoriteSongs,
            totalBytes: totalBytes,
            uiState: catalogUIState
        )
    }

    private func applyCatalogSnapshot(
        _ snapshot: DownloadCatalogSnapshot,
        replacingOptimisticState: Bool = false,
        committedSongIDs: Set<String>? = nil
    ) {
        objectWillChange.send()
        songById = snapshot.songById
        songIndexById = snapshot.songIndexById
        recordsByAlbumId = snapshot.recordsByAlbumId
        songs = snapshot.songs
        albums = snapshot.albums
        artists = snapshot.artists
        favoriteSongs = snapshot.favoriteSongs
        totalBytes = snapshot.totalBytes
        catalogUIState = snapshot.uiState

        if replacingOptimisticState {
            DownloadUIStateHub.shared.replace(with: snapshot.uiState)
        } else if let committedSongIDs {
            DownloadUIStateHub.shared.commitCatalogInsertions(
                snapshot.uiState,
                committedSongIDs: committedSongIDs
            )
        } else {
            DownloadUIStateHub.shared.commit(snapshot.uiState)
        }
        catalogPublisher.send(())
    }

    private func commitCurrentCatalogUIState() {
        let uiState = DownloadUIStateSnapshot(
            songIDs: Set(songById.keys),
            albumDownloadedCounts: recordsByAlbumId.mapValues(\.count),
            artistNames: Set(artists.map(\.name)),
            artistBadgeNames: DownloadCatalogBuilder.makeArtistBadgeNames(
                songs: songs,
                artists: artists
            ),
            totalBytes: totalBytes
        )
        catalogUIState = uiState
        DownloadUIStateHub.shared.commit(uiState)
    }

    func setActiveServer(_ serverId: String) async {
        guard self.serverId != serverId else { return }
        self.serverId = serverId
        KeepLibraryOfflineService.shared.prepare(serverId: serverId)
        let key = "shelv_artist_cover_by_name_\(serverId)"
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] {
            artistCoverByName = saved
        }
        await reload()
    }

    func updateArtistCovers(_ map: [String: String]) {
        artistCoverByName = map
        if !map.isEmpty && !serverId.isEmpty {
            UserDefaults.standard.set(map, forKey: "shelv_artist_cover_by_name_\(serverId)")
        }
        Task { await reload() }
    }

    func reload() async {
        guard !isDeletingAll else { pendingReload = true; return }
        guard !serverId.isEmpty else {
            catalogRevision &+= 1
            applyCatalogSnapshot(.empty, replacingOptimisticState: true)
            downloadedPlaylistIds = []; playlistSongIds = [:]
            return
        }
        guard !isLoading else { pendingReload = true; return }
        isLoading = true
        pendingReload = false
        catalogRevision &+= 1
        let revision = catalogRevision
        let sid = serverId
        let rawRecords = await DownloadDatabase.shared.allRecords(serverId: sid)
        // Container-UUID kann sich nach Updates ändern; Pfade neu berechnen falls Datei nicht mehr auffindbar
        let healResult = await Task.detached(priority: .utility) { () -> (records: [DownloadRecord], toUpdate: [DownloadRecord], toDelete: [DownloadRecord]) in
            var healed: [DownloadRecord] = []
            var toUpdate: [DownloadRecord] = []
            var toDelete: [DownloadRecord] = []
            for var record in rawRecords {
                if FileManager.default.fileExists(atPath: record.filePath) {
                    healed.append(record)
                } else {
                    let serverDir = DownloadService.serverDirectory(serverId: record.serverId)
                    let candidateNames = record.songId.pathSafeDownloadFileNameCandidates(
                        fileExtension: record.fileExtension,
                        storedFilePath: record.filePath
                    )

                    if let candidate = candidateNames
                        .map({ serverDir.appendingPathComponent($0) })
                        .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        record.filePath = candidate.path
                        toUpdate.append(record)
                        healed.append(record)
                    } else {
                        toDelete.append(record)
                    }
                }
            }
            return (records: healed, toUpdate: toUpdate, toDelete: toDelete)
        }.value
        for record in healResult.toUpdate {
            await DownloadDatabase.shared.upsert(record)
        }
        for record in healResult.toDelete {
            await DownloadDatabase.shared.delete(songId: record.songId, serverId: record.serverId)
        }
        let records = healResult.records
        let savedSongIds = UserDefaults.standard.dictionary(forKey: "shelv_mac_playlist_song_ids_\(sid)") as? [String: [String]] ?? [:]
        await DownloadDatabase.shared.adoptLegacyPlaylistMarkers(
            serverId: sid,
            playlistIds: Set(savedSongIds.keys)
        )
        let playlistIds = await DownloadDatabase.shared.loadDownloadedPlaylistIds(serverId: sid)
        let covers = artistCoverByName
        let snapshot = await Task.detached(priority: .utility) {
            DownloadCatalogBuilder.rebuilding(
                records,
                serverId: sid,
                artistCoverByName: covers
            )
        }.value

        guard serverId == sid, catalogRevision == revision else {
            isLoading = false
            pendingReload = false
            await reload()
            return
        }

        let mappedSongs = snapshot.songs
        let newSongById = snapshot.songById
        applyCatalogSnapshot(snapshot, replacingOptimisticState: true)
        // Geschützte IDs (DB-Schreibung noch ausstehend) mit DB-Stand zusammenführen;
        // sobald die DB sie enthält, Schutz aufheben.
        protectedPlaylistIds = protectedPlaylistIds.subtracting(playlistIds)
        downloadedPlaylistIds = playlistIds.union(protectedPlaylistIds)
        playlistSongIds = savedSongIds

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
            // Alle gespeicherten Artwork-Dateien (Album-Cover, Artist-Cover) indexieren
            let artDir = DownloadService.artworkDirectory(serverId: sid)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: artDir.path) {
                for file in files where file.hasSuffix(".jpg") {
                    let artId = String(file.dropLast(4))
                    dict[artId] = artDir.appendingPathComponent(file).path
                }
            }
            return dict
        }.value
        LocalArtworkIndex.shared.update(paths: artPaths)

        // Orphan-Playlist-Marker aufräumen: wenn keine Songs einer markierten Playlist
        // mehr lokal sind, darf sie im Offline-Modus nicht als Geist-Eintrag bleiben.
        let orphanedPlaylistIds = downloadedPlaylistIds.filter { id in
            guard !protectedPlaylistIds.contains(id) else { return false }
            guard let ids = playlistSongIds[id], !ids.isEmpty else { return true }
            return !ids.contains { newSongById[$0] != nil }
        }
        for id in orphanedPlaylistIds { unmarkPlaylistDownloaded(id: id) }

        isLoading = false
        if pendingReload {
            pendingReload = false
            await reload()
        }
    }

    // MARK: - Incremental Mutations

    func insertRecord(_ record: DownloadRecord) {
        guard !isDeletingAll else { return }
        guard record.serverId == serverId else { return }
        if isLoading { pendingReload = true; return }
        let song = record.toDownloadedSong()
        LocalDownloadIndex.shared.setPath(songId: song.songId, serverId: song.serverId, path: song.filePath)
        DownloadUIStateHub.shared.applyCompletedRecord(record)
        publishStatusChanges(forKeys: [DownloadService.key(songId: song.songId, serverId: song.serverId)])

        pendingInserts.append(record)
        if flushTask == nil {
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                await self?.flushPendingInserts()
            }
        }
    }

    private func flushPendingInserts() async {
        flushTask = nil
        guard !isFlushingCatalog else { return }
        guard !isLoading else {
            if !pendingInserts.isEmpty { pendingReload = true }
            pendingInserts = []
            return
        }
        guard !pendingInserts.isEmpty else { return }

        isFlushingCatalog = true
        while !pendingInserts.isEmpty, !isLoading {
            let records = pendingInserts
            pendingInserts = []
            let sid = serverId
            let revision = catalogRevision
            let current = currentCatalogSnapshot
            let covers = artistCoverByName
            let snapshot = await Task.detached(priority: .utility) {
                DownloadCatalogBuilder.applying(
                    records,
                    to: current,
                    serverId: sid,
                    artistCoverByName: covers
                )
            }.value

            guard serverId == sid, catalogRevision == revision, !isLoading else {
                if !isDeletingAll { pendingReload = true }
                break
            }

            for record in records where record.serverId == sid {
                let key = DownloadService.key(songId: record.songId, serverId: sid)
                inFlightStates.removeValue(forKey: key)
                inFlightProgress.removeValue(forKey: key)
            }
            applyCatalogSnapshot(
                snapshot,
                committedSongIDs: Set(records.map(\.songId))
            )
        }
        isFlushingCatalog = false

        if pendingReload, !isLoading {
            pendingReload = false
            await reload()
        }
    }

    func removeRecord(songId: String, serverId recordServerId: String) {
        guard recordServerId == serverId else { return }
        if isLoading { pendingReload = true; return }
        catalogRevision &+= 1
        pendingInserts.removeAll { $0.songId == songId }
        DownloadUIStateHub.shared.removeOptimisticRecord(songID: songId)
        LocalDownloadIndex.shared.setPath(songId: songId, serverId: serverId, path: nil)
        guard let song = songById[songId] else { return }
        objectWillChange.send()
        let albumId = song.albumId
        let albumArtist = albums.first(where: { $0.albumId == albumId })?.artistName
            ?? song.artistName
        let songServerId = song.serverId

        songById.removeValue(forKey: songId)
        totalBytes -= song.bytes

        recordsByAlbumId[albumId]?.removeAll { $0.songId == songId }
        let albumNowEmpty = recordsByAlbumId[albumId]?.isEmpty ?? true
        if albumNowEmpty { recordsByAlbumId.removeValue(forKey: albumId) }

        songs.removeAll { $0.songId == songId }
        songIndexById = Dictionary(
            uniqueKeysWithValues: songs.enumerated().map { ($0.element.songId, $0.offset) }
        )
        favoriteSongs.removeAll { $0.songId == songId }

        if let albumIdx = albums.firstIndex(where: { $0.albumId == albumId }) {
            if albumNowEmpty {
                albums.remove(at: albumIdx)
            } else {
                let old = albums[albumIdx]
                if let albumSongs = recordsByAlbumId[albumId], !albumSongs.isEmpty {
                    albums[albumIdx] = DownloadedAlbum(
                        albumId: old.albumId, serverId: old.serverId,
                        title: old.title, artistName: old.artistName,
                        artistId: old.artistId, coverArtId: old.coverArtId,
                        songs: albumSongs
                    )
                }
            }
        }

        if let artistIdx = artists.firstIndex(where: { $0.name == albumArtist }) {
            let remainingAlbums = albums.filter { $0.artistName == albumArtist }
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

        let affectedPlaylists = playlistSongIds.compactMap { (id, ids) in
            ids.contains(songId) ? id : nil
        }
        for playlistId in affectedPlaylists where downloadedCount(for: playlistId) == 0 {
            unmarkPlaylistDownloaded(id: playlistId)
        }
        commitCurrentCatalogUIState()
        catalogPublisher.send(())
        publishStatusChanges(forKeys: [DownloadService.key(songId: songId, serverId: serverId)])
    }

    // MARK: - Lookups

    func downloadedCount(for playlistId: String) -> Int {
        guard let ids = playlistSongIds[playlistId] else { return 0 }
        return ids.filter { isDownloaded(songId: $0) }.count
    }

    func isDownloaded(songId: String) -> Bool {
        songById[songId] != nil
    }

    func downloadState(songId: String) -> DownloadState {
        let key = DownloadService.key(songId: songId, serverId: serverId)
        if let p = inFlightProgress[key] { return .downloading(progress: p) }
        if let s = inFlightStates[key] { return s }
        return DownloadUIStateHub.shared.isSongDownloaded(songId) ? .completed : .none
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

    func artistDownloadStatus(artist: Artist, catalogAlbums: [Album]) -> AlbumDownloadStatus {
        let matchingAlbumsByID = catalogAlbums.filter { $0.artistId == artist.id }
        let matchingAlbums = matchingAlbumsByID.isEmpty
            ? catalogAlbums.filter {
                $0.artist?.compare(
                    artist.name,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
            : matchingAlbumsByID

        let downloadedArtist = artists.first { $0.artistId == artist.id }
            ?? artists.first {
                $0.name.compare(
                    artist.name,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
        let localDownloadedSongs = downloadedArtist?.albums.reduce(0) {
            $0 + $1.songs.count
        } ?? 0

        guard !matchingAlbums.isEmpty else {
            return localDownloadedSongs == 0
                ? .none
                : .partial(downloaded: localDownloadedSongs, total: localDownloadedSongs + 1)
        }

        let downloadedSongs = matchingAlbums.reduce(0) { result, album in
            result + (recordsByAlbumId[album.id]?.count ?? 0)
        }
        let effectiveDownloadedSongs = max(downloadedSongs, localDownloadedSongs)
        guard effectiveDownloadedSongs > 0 else { return .none }

        let expectedAlbumCount = artist.albumCount ?? matchingAlbums.count
        let hasCompleteCatalog = matchingAlbums.count >= expectedAlbumCount
            && matchingAlbums.allSatisfy { album in
                guard let totalSongs = album.songCount, totalSongs > 0 else { return false }
                return (recordsByAlbumId[album.id]?.count ?? 0) >= totalSongs
            }
        if hasCompleteCatalog { return .complete }

        let knownTotalSongs = matchingAlbums.reduce(0) { result, album in
            result + max(album.songCount ?? 0, 0)
        }
        return .partial(
            downloaded: effectiveDownloadedSongs,
            total: max(knownTotalSongs, effectiveDownloadedSongs + 1)
        )
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
        guard !isDeletingAll else { return }
        isDeletingAll = true
        downloadedPlaylistIds = []
        playlistSongIds = [:]
        protectedPlaylistIds = []
        UserDefaults.standard.removeObject(forKey: "shelv_mac_playlist_song_ids_\(serverId)")
        clearLocalDownloadState()
        Task {
            await DownloadService.shared.deleteAll()
            isDeletingAll = false
            await reload()
        }
    }

    private func clearLocalDownloadState() {
        let affectedSongIDs = Set(songs.map(\.songId)).union(
            inFlightStates.keys.compactMap(activeSongId(forKey:))
        )
        objectWillChange.send()
        catalogRevision &+= 1
        flushTask?.cancel()
        flushTask = nil
        pendingInserts = []
        songs = []
        albums = []
        artists = []
        favoriteSongs = []
        totalBytes = 0
        songById = [:]
        songIndexById = [:]
        recordsByAlbumId = [:]
        catalogUIState = .empty
        inFlightProgress = [:]
        inFlightStates = [:]
        DownloadActivityStore.shared.update(nil)
        pendingReload = false
        DownloadUIStateHub.shared.replace(with: .empty)
        catalogPublisher.send(())
        LocalDownloadIndex.shared.update(paths: [:])
        LocalArtworkIndex.shared.update(paths: [:])
        if !affectedSongIDs.isEmpty {
            progressPublisher.send(affectedSongIDs)
        }
    }

    func markPlaylistDownloaded(id: String, name: String, songIds: [String] = []) {
        downloadedPlaylistIds.insert(id)
        protectedPlaylistIds.insert(id)
        if !songIds.isEmpty {
            playlistSongIds[id] = songIds
            let key = "shelv_mac_playlist_song_ids_\(serverId)"
            var current = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
            current[id] = songIds
            UserDefaults.standard.set(current, forKey: key)
        }
        let sid = serverId
        Task {
            await DownloadDatabase.shared.markPlaylistDownloaded(
                id: id,
                name: name,
                serverId: sid
            )
        }
    }

    func syncPlaylistSongIds(_ id: String, songIds: [String]) {
        guard downloadedPlaylistIds.contains(id) else { return }
        playlistSongIds[id] = songIds
        let key = "shelv_mac_playlist_song_ids_\(serverId)"
        var current = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        current[id] = songIds
        UserDefaults.standard.set(current, forKey: key)
    }

    func unmarkPlaylistDownloaded(id: String) {
        downloadedPlaylistIds.remove(id)
        protectedPlaylistIds.remove(id)
        playlistSongIds.removeValue(forKey: id)
        let key = "shelv_mac_playlist_song_ids_\(serverId)"
        var current = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        current.removeValue(forKey: id)
        UserDefaults.standard.set(current, forKey: key)
        let sid = serverId
        Task { await DownloadDatabase.shared.unmarkPlaylistDownloaded(id: id, serverId: sid) }
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
