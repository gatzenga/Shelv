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

    @Published private(set) var songs: [DownloadedSong] = []
    @Published private(set) var albums: [DownloadedAlbum] = []
    @Published private(set) var artists: [DownloadedArtist] = []
    @Published private(set) var favoriteSongs: [DownloadedSong] = []
    @Published private(set) var totalBytes: Int64 = 0
    private(set) var inFlightProgress: [String: Double] = [:]
    private(set) var inFlightStates: [String: DownloadState] = [:]
    nonisolated(unsafe) let progressPublisher = PassthroughSubject<Set<String>, Never>()
    private let hasActiveDownloadsSubject = CurrentValueSubject<Bool, Never>(false)
    var hasActiveDownloadsPublisher: AnyPublisher<Bool, Never> {
        hasActiveDownloadsSubject.eraseToAnyPublisher()
    }
    var batchProgress: BatchProgress? { DownloadActivityStore.shared.batchProgress }
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var offlinePlaylistIds: Set<String> = []
    @Published private(set) var playlistSongIds: [String: [String]] = [:]

    private var songById: [String: DownloadedSong] = [:]
    private var songIndexById: [String: Int] = [:]
    private var recordsByAlbumId: [String: [DownloadedSong]] = [:]
    private var catalogUIState: DownloadUIStateSnapshot = .empty

    private var serverId: String = ""
    private var cancellables = Set<AnyCancellable>()
    private var artistCoverByName: [String: String] = [:]
    private var pendingReload = false
    private var reloadWaiters: [CheckedContinuation<Void, Never>] = []
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
                self.publishActiveDownloadAvailabilityIfNeeded()
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
                    switch update.state {
                    case .none:
                        didChange = self.inFlightStates.removeValue(forKey: update.key) != nil
                        didChange = self.inFlightProgress.removeValue(forKey: update.key) != nil || didChange
                    case .completed:
                        didChange = self.inFlightProgress.removeValue(forKey: update.key) != nil
                        if let songId = self.activeSongId(forKey: update.key), self.isDownloaded(songId: songId) {
                            didChange = self.inFlightStates.removeValue(forKey: update.key) != nil || didChange
                        } else if self.activeSongId(forKey: update.key) != nil {
                            if self.inFlightStates[update.key] != update.state {
                                self.inFlightStates[update.key] = update.state
                                didChange = true
                            }
                        } else {
                            didChange = self.inFlightStates.removeValue(forKey: update.key) != nil || didChange
                        }
                    default:
                        if self.inFlightStates[update.key] != update.state {
                            self.inFlightStates[update.key] = update.state
                            didChange = true
                        }
                    }
                    if didChange {
                        changedKeys.insert(update.key)
                    }
                }
                if !changedKeys.isEmpty {
                    self.publishActiveDownloadAvailabilityIfNeeded()
                    self.publishStatusChanges(forKeys: changedKeys)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .downloadsLibraryChanged)
            .sink { [weak self] _ in Task { @MainActor [weak self] in await self?.reload() } }
            .store(in: &cancellables)

        DownloadService.shared.batchUpdates
            .receive(on: DispatchQueue.main)
            .sink { progress in DownloadActivityStore.shared.update(progress) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .libraryArtistsLoaded)
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
        let songIds = Set(keys.compactMap(activeSongId(forKey:)))
        guard !songIds.isEmpty else { return }
        progressPublisher.send(songIds)
    }

    private func publishActiveDownloadAvailabilityIfNeeded() {
        let hasActiveDownloads = !inFlightProgress.isEmpty || !inFlightStates.isEmpty
        guard hasActiveDownloadsSubject.value != hasActiveDownloads else { return }
        hasActiveDownloadsSubject.send(hasActiveDownloads)
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
        guard self.serverId != serverId else {
            await waitForReloadIfNeeded()
            return
        }
        self.serverId = serverId
        KeepLibraryOfflineService.shared.prepare(serverId: serverId)
        let saved = UserDefaults.standard.stringArray(forKey: "shelv_offline_playlists_\(serverId)") ?? []
        offlinePlaylistIds = Set(saved)
        playlistSongIds = UserDefaults.standard.dictionary(forKey: "shelv_offline_playlist_songs_\(serverId)") as? [String: [String]] ?? [:]
        protectedPlaylistIds = []
        await reload()
    }

    func addOfflinePlaylist(_ id: String, name: String? = nil, songIds: [String]) {
        offlinePlaylistIds.insert(id)
        playlistSongIds[id] = songIds
        protectedPlaylistIds.insert(id)
        UserDefaults.standard.set(Array(offlinePlaylistIds), forKey: "shelv_offline_playlists_\(serverId)")
        UserDefaults.standard.set(playlistSongIds, forKey: "shelv_offline_playlist_songs_\(serverId)")
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let key = "shelv_offline_playlist_names_\(serverId)"
            var names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            names[id] = name
            UserDefaults.standard.set(names, forKey: key)
        }
    }

    func syncPlaylistSongIds(_ id: String, songIds: [String]) {
        guard offlinePlaylistIds.contains(id) else { return }
        playlistSongIds[id] = songIds
        UserDefaults.standard.set(playlistSongIds, forKey: "shelv_offline_playlist_songs_\(serverId)")
    }

    func removeOfflinePlaylist(_ id: String) {
        offlinePlaylistIds.remove(id)
        playlistSongIds.removeValue(forKey: id)
        protectedPlaylistIds.remove(id)
        UserDefaults.standard.set(Array(offlinePlaylistIds), forKey: "shelv_offline_playlists_\(serverId)")
        UserDefaults.standard.set(playlistSongIds, forKey: "shelv_offline_playlist_songs_\(serverId)")
        let namesKey = "shelv_offline_playlist_names_\(serverId)"
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names.removeValue(forKey: id)
        UserDefaults.standard.set(names, forKey: namesKey)
        let sid = serverId
        Task {
            await DownloadDatabase.shared.unmarkPlaylistDownloaded(
                id: id,
                serverId: sid
            )
        }
    }

    func downloadedCount(for playlistId: String) -> Int {
        guard let ids = playlistSongIds[playlistId] else { return 0 }
        return ids.filter { isDownloaded(songId: $0) }.count
    }

    func updateArtistCovers(_ map: [String: String]) {
        artistCoverByName = map
        Task { await reload() }
    }

    func reload() async {
        guard !isDeletingAll else { pendingReload = true; return }
        guard !serverId.isEmpty else {
            catalogRevision &+= 1
            applyCatalogSnapshot(.empty, replacingOptimisticState: true)
            return
        }
        guard !isLoading else {
            pendingReload = true
            await withCheckedContinuation { continuation in
                reloadWaiters.append(continuation)
            }
            return
        }
        isLoading = true
        pendingReload = false
        catalogRevision &+= 1
        let revision = catalogRevision
        let sid = serverId
        let rawRecords = await DownloadDatabase.shared.allRecords(serverId: sid)
        // App-Container-UUID im gespeicherten Pfad kann sich ändern; kanonischen Pfad neu berechnen wenn nötig.
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
            return (healed, toUpdate, toDelete)
        }.value
        for record in healResult.toUpdate {
            await DownloadDatabase.shared.upsert(record)
        }
        for record in healResult.toDelete {
            await DownloadDatabase.shared.delete(songId: record.songId, serverId: record.serverId)
        }
        let records = healResult.records
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

        var paths: [String: String] = [:]
        for song in mappedSongs {
            paths[LocalDownloadIndex.key(songId: song.songId, serverId: song.serverId)] = song.filePath
        }
        LocalDownloadIndex.shared.update(paths: paths)
        let artPaths = await Task.detached(priority: .utility) { () -> [String: String] in
            var dict: [String: String] = [:]
            let artDir = DownloadService.artworkDirectory(serverId: sid)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: artDir.path) {
                for file in files where file.hasSuffix(".jpg") {
                    let artId = String(file.dropLast(4))
                    dict[artId] = artDir.appendingPathComponent(file).path
                }
            }
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
        NotificationCenter.default.post(name: .artworkIndexReady, object: nil)
        // Sobald der erste Song einer geschützten Playlist heruntergeladen ist, Schutz aufheben.
        protectedPlaylistIds = protectedPlaylistIds.filter { id in
            guard let ids = playlistSongIds[id] else { return false }
            return !ids.contains { newSongById[$0] != nil }
        }
        // Orphan-Playlist-Marker aufräumen: Marker, deren Songs alle nicht mehr lokal sind,
        // entfernen — sonst Geist-Eintrag im Offline-Modus (z.B. nach „Delete All Downloads").
        // Geschützte Playlists (Download läuft, noch kein Song fertig) werden übersprungen.
        let orphanedPlaylistIds = offlinePlaylistIds.filter { id in
            guard !protectedPlaylistIds.contains(id) else { return false }
            guard let ids = playlistSongIds[id], !ids.isEmpty else { return true }
            return !ids.contains { newSongById[$0] != nil }
        }
        for id in orphanedPlaylistIds { removeOfflinePlaylist(id) }

        // The database snapshot is authoritative after a reload. Completion markers
        // are only a bridge until that snapshot (or the incremental insert) arrives.
        let completedKeys = Set(inFlightStates.compactMap { key, state -> String? in
            guard case .completed = state, activeSongId(forKey: key) != nil else { return nil }
            return key
        })
        for key in completedKeys {
            inFlightStates.removeValue(forKey: key)
            inFlightProgress.removeValue(forKey: key)
        }
        if !completedKeys.isEmpty {
            publishActiveDownloadAvailabilityIfNeeded()
            publishStatusChanges(forKeys: completedKeys)
        }

        isLoading = false
        if pendingReload {
            pendingReload = false
            await reload()
        }
        let waiters = reloadWaiters
        reloadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForReloadIfNeeded() async {
        guard isLoading else { return }
        await withCheckedContinuation { continuation in
            reloadWaiters.append(continuation)
        }
    }

    // MARK: - Incremental Mutations

    func insertRecord(_ record: DownloadRecord) {
        guard !isDeletingAll else { return }
        guard record.serverId == serverId else { return }
        if isLoading { pendingReload = true; return }

        // LocalDownloadIndex sofort aktualisieren — nötig damit der Player
        // heruntergeladene Songs unmittelbar lokal abspielen kann.
        let song = record.toDownloadedSong()
        LocalDownloadIndex.shared.setPath(songId: song.songId, serverId: song.serverId, path: song.filePath)

        // Keep the exact existing visual timing: completed songs and albums are
        // visible immediately while the catalog projection stays batched.
        DownloadUIStateHub.shared.applyCompletedRecord(record)

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
            publishActiveDownloadAvailabilityIfNeeded()
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
        // Song könnte noch im 800ms-Debounce-Buffer stecken (nach insertRecord, vor flushPendingInserts).
        // Hier rausnehmen, sonst erscheint er nach dem Flush doch noch in der UI.
        pendingInserts.removeAll { $0.songId == songId }
        DownloadUIStateHub.shared.removeOptimisticRecord(songID: songId)
        // LocalDownloadIndex wird in insertRecord sofort (vor dem Debounce) gesetzt — direkt löschen.
        LocalDownloadIndex.shared.setPath(songId: songId, serverId: serverId, path: nil)
        guard let song = songById[songId] else { return }
        let albumId = song.albumId
        let albumArtist = albums.first(where: { $0.albumId == albumId })?.artistName ?? song.artistName
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

        // Offline-Playlist-Marker aufräumen: wenn keine Songs der Playlist mehr lokal sind,
        // Marker entfernen damit die Playlist nicht als "Geist" in der Offline-Liste bleibt.
        let affectedPlaylists = playlistSongIds.compactMap { (id, ids) in
            ids.contains(songId) ? id : nil
        }
        for playlistId in affectedPlaylists where downloadedCount(for: playlistId) == 0 {
            removeOfflinePlaylist(playlistId)
        }
        commitCurrentCatalogUIState()
    }

    // MARK: - Lookups

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
        offlinePlaylistIds = []
        playlistSongIds = [:]
        UserDefaults.standard.removeObject(forKey: "shelv_offline_playlists_\(serverId)")
        UserDefaults.standard.removeObject(forKey: "shelv_offline_playlist_songs_\(serverId)")
        UserDefaults.standard.removeObject(forKey: "shelv_offline_playlist_names_\(serverId)")
        clearLocalDownloadState()
        Task {
            await DownloadService.shared.deleteAll()
            isDeletingAll = false
            await reload()
        }
    }

    private func clearLocalDownloadState() {
        catalogRevision &+= 1
        let affectedSongIds = Set(songs.map(\.songId)).union(
            inFlightStates.keys.compactMap(activeSongId(forKey:))
        )
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
        publishActiveDownloadAvailabilityIfNeeded()
        DownloadActivityStore.shared.update(nil)
        pendingReload = false
        protectedPlaylistIds = []
        DownloadUIStateHub.shared.replace(with: .empty)
        LocalDownloadIndex.shared.update(paths: [:])
        LocalArtworkIndex.shared.update(paths: [:])
        if !affectedSongIds.isEmpty {
            progressPublisher.send(affectedSongIds)
        }
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
