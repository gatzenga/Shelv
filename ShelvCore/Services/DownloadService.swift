import Foundation
@preconcurrency import Combine

// MARK: - Notifications

extension Notification.Name {
    nonisolated static let downloadStateChanged = Notification.Name("shelv.downloadStateChanged")
    nonisolated static let downloadsLibraryChanged = Notification.Name("shelv.downloadsLibraryChanged")
    nonisolated static let libraryArtistsLoaded = Notification.Name("shelv.libraryArtistsLoaded")
    nonisolated static let artworkIndexReady = Notification.Name("shelv.artworkIndexReady")
    nonisolated static let instantMixUnavailable = Notification.Name("shelv.instantMixUnavailable")
    // Geteilt statt pro Plattform definiert (tvOS braucht den Namen ebenfalls).
    nonisolated static let recapRegistryUpdated = Notification.Name("shelv.recapRegistryUpdated")
}

// MARK: - DownloadJob

private nonisolated struct DownloadJob: Codable {
    let song: Song
    let serverId: String
    var downloadURL: URL
    let coverURL: URL?
    let coverArtId: String?
    let artistCoverArtId: String?
    let artistCoverURL: URL?
    let albumArtistName: String?
    let albumCoverArtId: String?
    let albumCoverURL: URL?
    let albumId: String
    let albumTitle: String
    let artistName: String
    let artistId: String?
    let title: String
    let track: Int?
    let duration: Int?
    var fileExtension: String
    let isFavorite: Bool
    var requestedFormat: TranscodingCodec? = nil
    var fellBackToRaw: Bool = false
    var attempt: Int = 0
    var queuedAt: Date = Date()
}

private nonisolated struct BulkDownloadUnit: Sendable {
    let priority: Int
    let songs: [Song]
    let playlistMarker: BulkDownloadPlaylistMarker?
}

// MARK: - DownloadService

actor DownloadService {
    static let shared = DownloadService()

    private let coordinator = DownloadSessionCoordinator()
    private var session: URLSession?
    private let coverSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    private let backgroundIdentifier = "ch.vkugler.Shelv.downloads"
    private let maxConcurrent = 5
    private var effectiveMaxConcurrent: Int {
        TranscodingPolicy.currentDownloadFormat() != nil ? 1 : maxConcurrent
    }
    private let maxAttempts = 3

    private var pendingJobs: [DownloadJob] = []
    private var pendingJobKeys = Set<String>()
    private var inflightJobs: [Int: DownloadJob] = [:]   // taskIdentifier -> Job
    private var jobKeyByTask: [Int: String] = [:]         // taskIdentifier -> "serverId::songId"
    // Markiert Keys, deren Completion bei `cancel` bereits aus `inflightJobs` entfernt wurde —
    // verhindert dass eine `handleCompletion`, die an einem `await` suspendiert war, nach Resume
    // doch noch Datei + DB-Record schreibt. Wird in `enqueue` beim Re-Queue gelöscht.
    private var cancelledKeys = Set<String>()
    // Songs die gerade in handleCompletion laufen (aus inflightJobs entfernt, aber noch nicht committed).
    // jobSongIds prüft auch diese Map, damit deleteAlbum/deleteArtist auch in-completion Songs canceln kann.
    private var inCompletionJobs: [String: DownloadJob] = [:]  // key -> Job

    nonisolated(unsafe) private let progressSubject = CurrentValueSubject<[String: Double], Never>([:])
    nonisolated(unsafe) private let stateSubject = PassthroughSubject<(key: String, state: DownloadState), Never>()
    nonisolated(unsafe) private let batchSubject = CurrentValueSubject<BatchProgress?, Never>(nil)

    nonisolated var progressUpdates: AnyPublisher<[String: Double], Never> {
        progressSubject.eraseToAnyPublisher()
    }
    nonisolated var stateUpdates: AnyPublisher<(key: String, state: DownloadState), Never> {
        stateSubject.eraseToAnyPublisher()
    }
    nonisolated var batchUpdates: AnyPublisher<BatchProgress?, Never> {
        batchSubject.eraseToAnyPublisher()
    }

    private var batchTotal = 0
    private var batchCompleted = 0
    private var batchFailed = 0
    private var didRestoreExistingTasks = false
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        coordinator.service = self
    }

    static func key(songId: String, serverId: String) -> String {
        "\(serverId)::\(songId)"
    }

    // MARK: - Setup

    func setup() {
        if session == nil {
            #if os(iOS)
            // Background-Session: Downloads laufen im nsurlsessiond-Daemon weiter,
            // auch wenn iOS die App suspendiert. Restore via getAllTasks beim Start.
            let cfg = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            cfg.isDiscretionary = false
            cfg.sessionSendsLaunchEvents = true
            cfg.shouldUseExtendedBackgroundIdleMode = true
            #else
            // macOS: App läuft ohnehin weiter — Standard-Session wie in der
            // bisherigen Desktop-App (bewährtes Verhalten beibehalten).
            let cfg = URLSessionConfiguration.default
            #endif
            cfg.allowsCellularAccess = true
            cfg.httpMaximumConnectionsPerHost = maxConcurrent
            cfg.waitsForConnectivity = true
            let s = URLSession(configuration: cfg, delegate: coordinator, delegateQueue: nil)
            session = s
            s.getAllTasks { [weak self] tasks in
                Task {
                    guard let self else { return }
                    await self.restoreInflightTasks(tasks)
                    await self.markExistingTasksRestored()
                }
            }
        }
    }

    func waitForRestoredInflightTasks() async {
        setup()
        if didRestoreExistingTasks { return }
        await withCheckedContinuation { continuation in
            restoreWaiters.append(continuation)
        }
    }

    private func restoreInflightTasks(_ tasks: [URLSessionTask]) {
        for task in tasks {
            guard let downloadTask = task as? URLSessionDownloadTask,
                  let desc = downloadTask.taskDescription,
                  let job = decodeJob(desc) else { continue }
            let key = Self.key(songId: job.song.id, serverId: job.serverId)
            guard inflightJobs.values.contains(where: { Self.key(songId: $0.song.id, serverId: $0.serverId) == key }) == false else { continue }
            inflightJobs[downloadTask.taskIdentifier] = job
            jobKeyByTask[downloadTask.taskIdentifier] = key
            publishProgress(key: key, value: 0)
            stateSubject.send((key, .downloading(progress: 0)))
        }
    }

    private func markExistingTasksRestored() {
        didRestoreExistingTasks = true
        let waiters = restoreWaiters
        restoreWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func encodeJob(_ job: DownloadJob) -> String? {
        guard let data = try? JSONEncoder().encode(job) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJob(_ string: String) -> DownloadJob? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DownloadJob.self, from: data)
    }

    // MARK: - Enqueueing

    func enqueue(songs: [Song], serverId: String, albumArtistOverride: String? = nil, albumCoverArtIdOverride: String? = nil) async {
        guard await canStartDownloads() else { return }
        guard !songs.isEmpty else { return }
        guard let api = await currentAPI(for: serverId) else { return }
        let downloadedIds = await DownloadDatabase.shared.allSongIds(serverId: serverId)
        let artistCoverById: [String: String] = await MainActor.run {
            #if os(macOS)
            let artists = LibraryViewModel.shared.artists
            #elseif os(iOS)
            let artists = LibraryStore.shared.artists
            #else
            let artists: [Artist] = []   // tvOS: keine Downloads, kein Library-Store-Zugriff
            #endif
            return Dictionary(artists.compactMap { a in
                a.coverArt.map { (a.name, $0) }
            }, uniquingKeysWith: { first, _ in first })
        }

        // Album-Metadata pro Song-AlbumId nachschlagen wenn kein Override vorliegt.
        // Das verhindert dass beim Single-Song-/Playlist-Download der erste Song "gewinnt"
        // und das Album mit Track-Künstler/Track-Cover statt Album-Künstler/Album-Cover anlegt.
        var albumDetails: [String: (artist: String?, coverArt: String?)] = [:]
        if albumArtistOverride == nil || albumCoverArtIdOverride == nil {
            let neededIds = Set(songs.compactMap { $0.albumId }).filter { !$0.isEmpty }
            await withTaskGroup(of: (String, String?, String?)?.self) { group in
                for albumId in neededIds {
                    group.addTask {
                        guard let detail = try? await api.api.getAlbum(id: albumId) else { return nil }
                        return (albumId, detail.artist, detail.coverArt)
                    }
                }
                for await result in group {
                    if let (id, artist, cover) = result { albumDetails[id] = (artist, cover) }
                }
            }
        }

        var added = 0
        for song in songs {
            let key = Self.key(songId: song.id, serverId: serverId)
            if downloadedIds.contains(song.id) { continue }
            if inflightJobs.values.contains(where: { Self.key(songId: $0.song.id, serverId: $0.serverId) == key }) { continue }
            if pendingJobKeys.contains(key) { continue }
            // Stale Cancel-Marker beim Neu-Enqueue entfernen — sonst würde eine spätere
            // Completion fälschlich als "cancelled" interpretiert.
            cancelledKeys.remove(key)
            let transcoding = TranscodingPolicy.currentDownloadFormat()
            guard let url = api.api.downloadURL(for: song.id, server: api.server, password: api.password,
                                                transcoding: transcoding) else { continue }
            let cover = song.coverArt.flatMap { api.api.coverArtURL(for: $0, server: api.server, password: api.password, size: 600) }
            let artistCoverArtId = artistCoverById[song.artist ?? ""]
            let artistCoverURL: URL? = artistCoverArtId.flatMap {
                api.api.coverArtURL(for: $0, server: api.server, password: api.password, size: 600)
            }
            // Override > Lookup > nil
            let lookedUp = song.albumId.flatMap { albumDetails[$0] }
            let resolvedAlbumArtist = albumArtistOverride ?? lookedUp?.artist
            let resolvedAlbumCover  = albumCoverArtIdOverride ?? lookedUp?.coverArt
            let albumCoverURL: URL? = resolvedAlbumCover.flatMap {
                api.api.coverArtURL(for: $0, server: api.server, password: api.password, size: 600)
            }
            let initialExt: String = {
                if let t = transcoding { return t.codec.fileExtension }
                return song.suffix?.pathSafeFileExtension() ?? "mp3"
            }()
            let job = DownloadJob(
                song: song,
                serverId: serverId,
                downloadURL: url,
                coverURL: cover,
                coverArtId: song.coverArt,
                artistCoverArtId: artistCoverArtId,
                artistCoverURL: artistCoverURL,
                albumArtistName: resolvedAlbumArtist,
                albumCoverArtId: resolvedAlbumCover,
                albumCoverURL: albumCoverURL,
                albumId: song.albumId ?? "",
                albumTitle: song.album ?? "",
                artistName: song.artist ?? "",
                artistId: song.artistId,
                title: song.title,
                track: song.track,
                duration: song.duration,
                fileExtension: initialExt,
                isFavorite: false,
                requestedFormat: transcoding?.codec
            )
            pendingJobs.append(job)
            pendingJobKeys.insert(key)
            stateSubject.send((key, .queued))
            added += 1
        }
        if added > 0 { incrementBatchTotal(by: added) }
        startNextJobs()
    }

    func enqueueAlbum(album: Album, serverId: String) async {
        guard await canStartDownloads() else { return }
        guard let api = await currentAPI(for: serverId) else { return }
        do {
            let detail = try await api.api.getAlbum(id: album.id)
            let songs = (detail.song ?? []).map { song -> Song in
                if song.artist != nil { return song }
                return Song(
                    id: song.id, title: song.title,
                    artist: detail.artist, artistId: song.artistId,
                    album: song.album ?? detail.name,
                    albumId: song.albumId ?? detail.id, track: song.track, discNumber: song.discNumber,
                    duration: song.duration, coverArt: song.coverArt ?? detail.coverArt,
                    year: song.year, genre: song.genre, playCount: song.playCount,
                    starred: song.starred, contentType: song.contentType, suffix: song.suffix,
                    fileSize: song.fileSize, bitRate: song.bitRate, bitDepth: song.bitDepth,
                    samplingRate: song.samplingRate, channelCount: song.channelCount, bpm: song.bpm,
                    comment: song.comment, musicBrainzId: song.musicBrainzId, isrc: song.isrc,
                    genres: song.genres, artists: song.artists, displayArtist: song.displayArtist,
                    albumArtists: song.albumArtists, displayAlbumArtist: song.displayAlbumArtist,
                    contributors: song.contributors, displayComposer: song.displayComposer,
                    moods: song.moods, explicitStatus: song.explicitStatus, works: song.works,
                    movements: song.movements, groupings: song.groupings,
                    replayGain: song.replayGain
                )
            }
            let albumArtist = detail.artist ?? album.artist
            await enqueue(songs: songs, serverId: serverId,
                         albumArtistOverride: albumArtist,
                         albumCoverArtIdOverride: detail.coverArt)
        } catch {
            DBErrorLog.logPlayLog("DownloadService.enqueueAlbum: \(error.localizedDescription)")
        }
    }

    func enqueueArtist(artist: Artist, serverId: String) async {
        guard await canStartDownloads() else { return }
        guard let api = await currentAPI(for: serverId) else { return }
        do {
            let detail = try await api.api.getArtist(id: artist.id)
            for album in detail.album ?? [] {
                await enqueueAlbum(album: album, serverId: serverId)
            }
        } catch {
            DBErrorLog.logPlayLog("DownloadService.enqueueArtist: \(error.localizedDescription)")
        }
    }

    private func canStartDownloads() async -> Bool {
        await MainActor.run { !OfflineModeService.shared.isOffline }
    }

    // MARK: - Cancel / Delete

    func cancel(songId: String, serverId: String) {
        let key = Self.key(songId: songId, serverId: serverId)
        // Markieren: falls eine `handleCompletion` parallel läuft und an einem await suspendiert ist,
        // bricht sie nach Resume ab und räumt die geschriebene Datei wieder auf.
        cancelledKeys.insert(key)
        let removedPending = pendingJobs.filter { Self.key(songId: $0.song.id, serverId: $0.serverId) == key }.count
        pendingJobs.removeAll { Self.key(songId: $0.song.id, serverId: $0.serverId) == key }
        if removedPending > 0 { pendingJobKeys.remove(key) }
        var removedInflight = 0
        let matchingTaskIds = inflightJobs
            .filter { Self.key(songId: $1.song.id, serverId: $1.serverId) == key }
            .map { $0.key }
        for taskId in matchingTaskIds {
            session?.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskId })?.cancel()
            }
            inflightJobs.removeValue(forKey: taskId)
            jobKeyByTask.removeValue(forKey: taskId)
            removedInflight += 1
        }
        publishProgress(key: key, value: nil)
        stateSubject.send((key, .none))
        let inCompletion = inCompletionJobs.values.contains { Self.key(songId: $0.song.id, serverId: $0.serverId) == key } ? 1 : 0
        let removed = removedPending + removedInflight + inCompletion
        if removed > 0 {
            batchTotal = max(0, batchTotal - removed)
            publishBatch()
            resetBatchIfDone()
        }
    }

    func delete(songId: String, serverId: String) async {
        cancel(songId: songId, serverId: serverId)
        if let path = await DownloadDatabase.shared.filePath(songId: songId, serverId: serverId) {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: path))
        }
        await DownloadDatabase.shared.delete(songId: songId, serverId: serverId)
        let key = Self.key(songId: songId, serverId: serverId)
        stateSubject.send((key, .none))
        await DownloadStore.shared.removeRecord(songId: songId)
    }

    func deleteAlbum(albumId: String, serverId: String) async {
        let queuedSongIds = jobSongIds(matching: { $0.albumId == albumId && $0.serverId == serverId })
        for songId in queuedSongIds { cancel(songId: songId, serverId: serverId) }

        let records = await DownloadDatabase.shared.allRecords(serverId: serverId)
            .filter { $0.albumId == albumId }
        for r in records {
            cancel(songId: r.songId, serverId: serverId)
            try? FileManager.default.removeItem(atPath: r.filePath)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: r.filePath))
            await DownloadDatabase.shared.delete(songId: r.songId, serverId: serverId)
            stateSubject.send((Self.key(songId: r.songId, serverId: serverId), .none))
            await DownloadStore.shared.removeRecord(songId: r.songId)
        }
    }

    func deleteArtist(artistId: String, serverId: String) async {
        let isNameKey = artistId.hasPrefix("name:")
        let lookupName = isNameKey ? String(artistId.dropFirst("name:".count)) : artistId

        let queuedSongIds = jobSongIds(matching: { job in
            guard job.serverId == serverId else { return false }
            if isNameKey { return job.artistName == lookupName }
            return job.artistId == artistId || job.artistName == lookupName
        })
        for songId in queuedSongIds { cancel(songId: songId, serverId: serverId) }

        let all = await DownloadDatabase.shared.allRecords(serverId: serverId)
        let records: [DownloadRecord]
        if isNameKey {
            records = all.filter { $0.artistName == lookupName }
        } else {
            records = all.filter { $0.artistId == artistId || $0.artistName == artistId }
        }
        for r in records {
            cancel(songId: r.songId, serverId: serverId)
            try? FileManager.default.removeItem(atPath: r.filePath)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: r.filePath))
            await DownloadDatabase.shared.delete(songId: r.songId, serverId: serverId)
            stateSubject.send((Self.key(songId: r.songId, serverId: serverId), .none))
            await DownloadStore.shared.removeRecord(songId: r.songId)
        }
    }

    private func jobSongIds(matching predicate: (DownloadJob) -> Bool) -> [String] {
        var ids: [String] = []
        ids.append(contentsOf: pendingJobs.filter(predicate).map { $0.song.id })
        ids.append(contentsOf: inflightJobs.values.filter(predicate).map { $0.song.id })
        ids.append(contentsOf: inCompletionJobs.values.filter(predicate).map { $0.song.id })
        return ids
    }

    func cancelBatch() {
        let pendingKeys = pendingJobs.map { Self.key(songId: $0.song.id, serverId: $0.serverId) }
        pendingJobs.removeAll()
        pendingJobKeys.removeAll()
        let inflightKeys = inflightJobs.values.map { Self.key(songId: $0.song.id, serverId: $0.serverId) }
        for taskId in Array(inflightJobs.keys) {
            inflightJobs.removeValue(forKey: taskId)
            jobKeyByTask.removeValue(forKey: taskId)
        }
        let completionKeys = Array(inCompletionJobs.keys)
        for key in pendingKeys + inflightKeys + completionKeys { cancelledKeys.insert(key) }
        session?.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        for key in pendingKeys + inflightKeys + completionKeys {
            publishProgress(key: key, value: nil)
            stateSubject.send((key, .none))
        }
        batchTotal = 0; batchCompleted = 0; batchFailed = 0
        batchSubject.send(nil)
    }

    func deleteAllForServer(_ serverId: String) async {
        let activeSongIds = Set(jobSongIds(matching: { $0.serverId == serverId }))
        for songId in activeSongIds {
            cancel(songId: songId, serverId: serverId)
        }
        let records = await DownloadDatabase.shared.allRecords(serverId: serverId)
        for r in records {
            cancel(songId: r.songId, serverId: serverId)
            try? FileManager.default.removeItem(atPath: r.filePath)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: r.filePath))
        }
        await DownloadDatabase.shared.deleteAllForServer(serverId)
        // Server-Verzeichnis räumen
        let dir = Self.serverDirectory(serverId: serverId)
        try? FileManager.default.removeItem(at: dir)
        notifyLibraryChanged()
    }

    func deleteAll() async {
        // Cancel aller Downloads FIRST — bevor wir Files anfassen
        cancelBatch()

        // DB leeren (rows weg, Pool bleibt offen mit leerer DB)
        await DownloadDatabase.shared.deleteAll()

        // Dann Audio-/Cover-Files löschen — ABER DB-Datei + WAL + SHM skippen,
        // sonst "vnode unlinked while in use" weil Pool sie noch offen hält.
        // Vergleich via lastPathComponent statt vollem Pfad — /var vs /private/var Symlink-Unterschiede
        // machen Pfadvergleiche unzuverlässig.
        let root = Self.rootDirectory()
        let dbFileName = DownloadDatabase.dbURL.lastPathComponent
        if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for url in entries {
                let name = url.lastPathComponent
                if name == dbFileName || name == dbFileName + "-wal" || name == dbFileName + "-shm" { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }

        progressSubject.send([:])
        batchTotal = 0; batchCompleted = 0; batchFailed = 0
        batchSubject.send(nil)
        notifyLibraryChanged()
    }

    // MARK: - Bulk Plan

    func planBulkDownload(serverId: String, maxBytes: Int64,
                          favorites enabled: Bool,
                          recapPlaylistIds: [String] = [],
                          libraryAlbums: [Album]) async -> BulkDownloadPlan {
        guard let api = await currentAPI(for: serverId) else {
            return BulkDownloadPlan(planned: [], skipped: [], totalBytes: 0, limitBytes: maxBytes)
        }
        let alreadyDownloaded = await DownloadDatabase.shared.allSongIds(serverId: serverId)
        let apiService = api.api

        async let discoverFreqTask = (try? await apiService.getAlbumList(type: "frequent", size: 20)) ?? []
        async let discoverRecentTask = (try? await apiService.getAlbumList(type: "recent", size: 20)) ?? []
        async let discoverNewestTask = (try? await apiService.getAlbumList(type: "newest", size: 50)) ?? []
        async let albumPairsTask = fetchAlbumSongPairs(api: apiService, albums: libraryAlbums)
        async let playlistPairsTask = fetchPlaylistSongPairs(api: apiService, recapPlaylistIds: recapPlaylistIds)

        let discoverFreq = await discoverFreqTask
        let discoverRecent = await discoverRecentTask
        let discoverNewest = await discoverNewestTask
        let albumPairs = await albumPairsTask
        let playlistPairs = await playlistPairsTask

        let albumSongsById = Dictionary(albumPairs.map { ($0.album.id, sortAlbumSongs($0.songs)) },
                                        uniquingKeysWith: { first, _ in first })

        var units: [BulkDownloadUnit] = []
        var usedAlbumIds = Set<String>()

        func addAlbumUnit(albumId: String, priority: Int) {
            guard usedAlbumIds.insert(albumId).inserted,
                  let songs = albumSongsById[albumId],
                  !songs.isEmpty
            else { return }
            units.append(BulkDownloadUnit(
                priority: priority,
                songs: songs,
                playlistMarker: nil
            ))
        }

        for album in discoverFreq.enumerated() {
            addAlbumUnit(albumId: album.element.id, priority: 0 + album.offset)
        }
        for album in discoverRecent.enumerated() {
            addAlbumUnit(albumId: album.element.id, priority: 1_000 + album.offset)
        }

        if enabled {
            let favoriteAlbums = albumPairs
                .compactMap { pair -> (albumId: String, starred: Date)? in
                    let newestStar = pair.songs.compactMap(\.starred).max()
                    return newestStar.map { (pair.album.id, $0) }
                }
                .sorted { $0.starred > $1.starred }
            for item in favoriteAlbums.enumerated() {
                addAlbumUnit(albumId: item.element.albumId, priority: 2_000 + item.offset)
            }
        }

        for album in discoverNewest.enumerated() {
            addAlbumUnit(albumId: album.element.id, priority: 3_000 + album.offset)
        }

        var recapPlaylistSongIdsMap: [String: [String]] = [:]
        for playlist in playlistPairs.recap.enumerated() {
            let songs = playlist.element.songs
            recapPlaylistSongIdsMap[playlist.element.id] = songs.map(\.id)
            guard !songs.isEmpty else { continue }
            units.append(BulkDownloadUnit(
                priority: 4_000 + playlist.offset,
                songs: songs,
                playlistMarker: BulkDownloadPlaylistMarker(
                    id: playlist.element.id,
                    name: playlist.element.name,
                    songIds: songs.map(\.id)
                )
            ))
        }

        for playlist in playlistPairs.normal.enumerated() {
            let songs = playlist.element.songs
            guard !songs.isEmpty else { continue }
            units.append(BulkDownloadUnit(
                priority: 5_000 + playlist.offset,
                songs: songs,
                playlistMarker: BulkDownloadPlaylistMarker(
                    id: playlist.element.id,
                    name: playlist.element.name,
                    songIds: songs.map(\.id)
                )
            ))
        }

        let remainingAlbums = albumPairs
            .filter { !usedAlbumIds.contains($0.album.id) && !$0.songs.isEmpty }
            .sorted {
                let aArtist = ($0.album.artist ?? "").lowercased()
                let bArtist = ($1.album.artist ?? "").lowercased()
                if aArtist != bArtist { return aArtist < bArtist }
                return $0.album.name.lowercased() < $1.album.name.lowercased()
            }
        for album in remainingAlbums.enumerated() {
            addAlbumUnit(albumId: album.element.album.id, priority: 6_000 + album.offset)
        }

        let targetBitrate = TranscodingPolicy.currentDownloadFormat()?.bitrate
        var planned: [Song] = []
        var skipped: [Song] = []
        var plannedIds = Set<String>()
        var skippedIds = Set<String>()
        var playlistMarkers: [BulkDownloadPlaylistMarker] = []
        var playlistMarkerIds = Set<String>()
        var totalBytes: Int64 = 0

        func appendPlaylistMarker(_ marker: BulkDownloadPlaylistMarker?) {
            guard let marker, playlistMarkerIds.insert(marker.id).inserted else { return }
            playlistMarkers.append(marker)
        }

        for unit in units.sorted(by: { $0.priority < $1.priority }) {
            let missingSongs = unit.songs.filter {
                !alreadyDownloaded.contains($0.id) && !plannedIds.contains($0.id)
            }
            if missingSongs.isEmpty {
                appendPlaylistMarker(unit.playlistMarker)
                continue
            }
            let packageBytes = missingSongs.reduce(Int64(0)) {
                $0 + estimatedBytes(for: $1, targetBitrate: targetBitrate)
            }
            if totalBytes + packageBytes <= maxBytes {
                planned.append(contentsOf: missingSongs)
                plannedIds.formUnion(missingSongs.map(\.id))
                totalBytes += packageBytes
                appendPlaylistMarker(unit.playlistMarker)
            } else {
                for song in missingSongs where skippedIds.insert(song.id).inserted {
                    skipped.append(song)
                }
            }
        }

        return BulkDownloadPlan(
            planned: planned,
            skipped: skipped,
            totalBytes: totalBytes,
            limitBytes: maxBytes,
            playlistMarkers: playlistMarkers,
            recapPlaylistSongIds: recapPlaylistSongIdsMap
        )
    }

    func planKeepLibraryOffline(
        serverId: String,
        maxBytes: Int64,
        favorites enabled: Bool,
        recapPlaylistIds: [String] = [],
        libraryAlbums: [Album],
        forceFullScan: Bool = false
    ) async -> BulkDownloadPlan {
        let countsByAlbum = await DownloadDatabase.shared.songCountsByAlbum(serverId: serverId)
        let candidateAlbums = libraryAlbums.filter { album in
            if forceFullScan { return true }
            guard let expected = album.songCount, expected > 0 else { return true }
            return (countsByAlbum[album.id] ?? 0) < expected
        }

        var plan = await planBulkDownload(
            serverId: serverId,
            maxBytes: maxBytes,
            favorites: enabled,
            recapPlaylistIds: recapPlaylistIds,
            libraryAlbums: candidateAlbums
        )
        plan = BulkDownloadPlan(
            planned: plan.planned,
            skipped: plan.skipped,
            totalBytes: plan.totalBytes,
            limitBytes: maxBytes,
            isKeepLibraryOffline: true,
            playlistMarkers: plan.playlistMarkers,
            recapPlaylistSongIds: plan.recapPlaylistSongIds
        )
        return plan
    }

    private func fetchAlbumSongPairs(api: SubsonicAPIService, albums: [Album]) async -> [(album: Album, songs: [Song])] {
        await withTaskGroup(of: (Album, [Song]).self) { group in
            let limit = 10
            var index = 0
            var result: [(Album, [Song])] = []
            for album in albums.prefix(limit) {
                group.addTask { (album, (try? await api.getAlbum(id: album.id))?.song ?? []) }
                index += 1
            }
            for await pair in group {
                result.append(pair)
                if index < albums.count {
                    let next = albums[index]
                    group.addTask { (next, (try? await api.getAlbum(id: next.id))?.song ?? []) }
                    index += 1
                }
            }
            return result
        }
    }

    private func fetchPlaylistSongPairs(
        api: SubsonicAPIService,
        recapPlaylistIds: [String]
    ) async -> (recap: [(id: String, name: String, songs: [Song])], normal: [(id: String, name: String, songs: [Song])]) {
        let recapIdSet = Set(recapPlaylistIds)
        async let recapTask = fetchPlaylistDetails(api: api, playlists: recapPlaylistIds.map { (id: $0, name: "") })
        async let normalTask = fetchNormalPlaylistDetails(api: api, excluding: recapIdSet)
        return (await recapTask, await normalTask)
    }

    private func fetchNormalPlaylistDetails(
        api: SubsonicAPIService,
        excluding excludedIds: Set<String>
    ) async -> [(id: String, name: String, songs: [Song])] {
        let playlists = (try? await api.getPlaylists()) ?? []
        let normal = playlists
            .filter { !excludedIds.contains($0.id) }
            .map { (id: $0.id, name: $0.name) }
        return await fetchPlaylistDetails(api: api, playlists: normal)
    }

    private func fetchPlaylistDetails(
        api: SubsonicAPIService,
        playlists: [(id: String, name: String)]
    ) async -> [(id: String, name: String, songs: [Song])] {
        await withTaskGroup(of: (Int, String, String, [Song]).self) { group in
            let limit = 8
            var index = 0
            var result: [(Int, String, String, [Song])] = []
            for playlist in playlists.prefix(limit) {
                let currentIndex = index
                group.addTask {
                    let detail = try? await api.getPlaylist(id: playlist.id)
                    return (
                        currentIndex,
                        playlist.id,
                        detail?.name ?? playlist.name,
                        detail?.songs ?? []
                    )
                }
                index += 1
            }
            for await item in group {
                result.append(item)
                if index < playlists.count {
                    let playlist = playlists[index]
                    let currentIndex = index
                    group.addTask {
                        let detail = try? await api.getPlaylist(id: playlist.id)
                        return (
                            currentIndex,
                            playlist.id,
                            detail?.name ?? playlist.name,
                            detail?.songs ?? []
                        )
                    }
                    index += 1
                }
            }
            return result
                .sorted { $0.0 < $1.0 }
                .map { (_, id, name, songs) in (id, name, songs) }
        }
    }

    private func sortAlbumSongs(_ songs: [Song]) -> [Song] {
        songs.sorted {
            let aDisc = $0.discNumber ?? 0
            let bDisc = $1.discNumber ?? 0
            if aDisc != bDisc { return aDisc < bDisc }
            let aTrack = $0.track ?? 0
            let bTrack = $1.track ?? 0
            if aTrack != bTrack { return aTrack < bTrack }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func estimatedBytes(for song: Song, targetBitrate: Int? = nil) -> Int64 {
        let kbps = targetBitrate ?? song.bitRate ?? 192
        let duration = song.duration ?? 200
        return Int64(kbps) * Int64(duration) * 1024 / 8
    }

    // MARK: - Status / Lookups

    func currentState(songId: String, serverId: String) -> DownloadState {
        let key = Self.key(songId: songId, serverId: serverId)
        if let p = progressSubject.value[key] { return .downloading(progress: p) }
        if pendingJobs.contains(where: { Self.key(songId: $0.song.id, serverId: $0.serverId) == key }) {
            return .queued
        }
        return .none
    }

    // MARK: - Job Lifecycle

    private func startNextJobs() {
        guard let session else { return }
        while inflightJobs.count < effectiveMaxConcurrent && !pendingJobs.isEmpty {
            let job = pendingJobs.removeFirst()
            let jobKey = Self.key(songId: job.song.id, serverId: job.serverId)
            pendingJobKeys.remove(jobKey)
            let task = session.downloadTask(with: job.downloadURL)
            if let desc = encodeJob(job) { task.taskDescription = desc }
            inflightJobs[task.taskIdentifier] = job
            jobKeyByTask[task.taskIdentifier] = jobKey
            let initialProgress: Double = job.requestedFormat != nil ? -1 : 0
            publishProgress(key: jobKey, value: initialProgress)
            stateSubject.send((jobKey, .downloading(progress: initialProgress)))
            task.resume()
        }
    }

    func handleProgress(taskIdentifier: Int, written: Int64, total: Int64) {
        guard let key = jobKeyByTask[taskIdentifier] else { return }
        let p = total > 0 ? Double(written) / Double(total) : -1
        publishProgress(key: key, value: p)
        stateSubject.send((key, .downloading(progress: p)))
    }

    func handleCompletion(taskIdentifier: Int, tempURL: URL, byteSize: Int64, statusCode: Int?, mimeType: String?, taskDescription: String?) async {
        let job: DownloadJob
        if let existing = inflightJobs[taskIdentifier] {
            job = existing
            inflightJobs.removeValue(forKey: taskIdentifier)
            jobKeyByTask.removeValue(forKey: taskIdentifier)
        } else if let desc = taskDescription, let decoded = decodeJob(desc) {
            job = decoded
        } else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        let key = Self.key(songId: job.song.id, serverId: job.serverId)
        inCompletionJobs[key] = job
        defer { inCompletionJobs.removeValue(forKey: key) }

        // Race-Window 1: User cancel-te zwischen erstem `await` und jetzt.
        if cancelledKeys.contains(key) {
            cancelledKeys.remove(key)
            try? FileManager.default.removeItem(at: tempURL)
            publishProgress(key: key, value: nil)
            stateSubject.send((key, .none))
            return
        }

        let validation: DownloadPayloadValidation
        do {
            validation = try await DownloadPayloadValidator.validate(
                fileURL: tempURL,
                byteSize: byteSize,
                statusCode: statusCode,
                mimeType: mimeType,
                fallbackFileExtension: job.fileExtension
            )
        } catch {
            DBErrorLog.logPlayLog("DownloadService validation failed for \(job.title): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            await retryOrFail(job: job, error: error)
            return
        }

        if cancelledKeys.contains(key) {
            cancelledKeys.remove(key)
            try? FileManager.default.removeItem(at: tempURL)
            publishProgress(key: key, value: nil)
            stateSubject.send((key, .none))
            return
        }

        let serverDir = Self.serverDirectory(serverId: job.serverId)
        let actualExt = (validation.fileExtension ?? job.fileExtension).pathSafeFileExtension()
        let finalURL = serverDir.appendingPathComponent("\(job.song.id.pathSafeComponent).\(actualExt)")

        do {
            try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            DBErrorLog.logPlayLog("DownloadService move failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            await retryOrFail(job: job, error: error)
            return
        }

        await downloadAssetsIfNeeded(for: job, audioPath: finalURL.path)

        // Race-Window 2: User cancel-te während Cover/Asset-Download (await downloadAssetsIfNeeded).
        // Datei liegt schon auf Disk → wieder löschen, KEIN DB-Record schreiben.
        if cancelledKeys.contains(key) {
            cancelledKeys.remove(key)
            try? FileManager.default.removeItem(atPath: finalURL.path)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: finalURL.path))
            publishProgress(key: key, value: nil)
            stateSubject.send((key, .none))
            return
        }

        let bytes = byteSize > 0 ? byteSize :
            (Int64((try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? 0))

        let record = DownloadRecord(
            songId: job.song.id,
            serverId: job.serverId,
            albumId: job.albumId,
            artistId: job.artistId,
            title: job.title,
            albumTitle: job.albumTitle,
            artistName: job.artistName,
            track: job.track,
            disc: job.song.discNumber,
            duration: job.duration,
            year: job.song.year,
            genre: job.song.genre,
            playCount: job.song.playCount,
            explicitStatus: job.song.explicitStatus,
            bytes: bytes,
            coverArtId: job.coverArtId,
            artistCoverArtId: job.artistCoverArtId,
            albumArtistName: job.albumArtistName,
            albumCoverArtId: job.albumCoverArtId,
            isFavorite: job.isFavorite,
            filePath: finalURL.path,
            fileExtension: actualExt,
            contentType: validation.contentType ?? job.song.contentType,
            bitRate: job.song.bitRate,
            bitDepth: job.song.bitDepth,
            samplingRate: job.song.samplingRate,
            channelCount: job.song.channelCount,
            bpm: job.song.bpm,
            replayGainTrackGain: job.song.replayGain?.trackGain,
            replayGainAlbumGain: job.song.replayGain?.albumGain,
            addedAt: Date().timeIntervalSince1970
        )
        await DownloadDatabase.shared.upsert(record)

        // Race-Window 3: Cancel landete während `await upsert` — DB-Row wieder löschen + Datei weg.
        if cancelledKeys.contains(key) {
            cancelledKeys.remove(key)
            try? FileManager.default.removeItem(atPath: finalURL.path)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: finalURL.path))
            await DownloadDatabase.shared.delete(songId: job.song.id, serverId: job.serverId)
            publishProgress(key: key, value: nil)
            stateSubject.send((key, .none))
            return
        }

        publishProgress(key: key, value: nil)
        stateSubject.send((key, .completed))
        await DownloadStore.shared.insertRecord(record)

        // Race-Window 4: Cancel landete während `await insertRecord` — komplett zurückrollen.
        if cancelledKeys.contains(key) {
            cancelledKeys.remove(key)
            try? FileManager.default.removeItem(atPath: finalURL.path)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: finalURL.path))
            await DownloadDatabase.shared.delete(songId: job.song.id, serverId: job.serverId)
            await DownloadStore.shared.removeRecord(songId: job.song.id)
            stateSubject.send((key, .none))
            return
        }

        incrementBatchCompleted()
        startNextJobs()
    }

    func handleError(taskIdentifier: Int, error: Error?, taskDescription: String?) async {
        let job: DownloadJob
        if let existing = inflightJobs.removeValue(forKey: taskIdentifier) {
            job = existing
            jobKeyByTask.removeValue(forKey: taskIdentifier)
        } else if let desc = taskDescription, let decoded = decodeJob(desc) {
            job = decoded
            jobKeyByTask.removeValue(forKey: taskIdentifier)
        } else {
            jobKeyByTask.removeValue(forKey: taskIdentifier)
            return
        }
        await retryOrFail(job: job, error: error ?? NSError(domain: "DownloadService", code: 0))
    }

    private func retryOrFail(job: DownloadJob, error: Error) async {
        let key = Self.key(songId: job.song.id, serverId: job.serverId)
        if cancelledKeys.contains(key) {
            cancelledKeys.remove(key)
            publishProgress(key: key, value: nil)
            stateSubject.send((key, .none))
            startNextJobs()
            return
        }

        if isStorageCapacityError(error) {
            await pauseKeepOfflineForStorageFailure(job: job, error: error)
            return
        }

        var next = job
        next.attempt += 1
        if next.attempt < maxAttempts {
            let backoff = pow(2.0, Double(next.attempt))
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            if cancelledKeys.contains(key) {
                cancelledKeys.remove(key)
                publishProgress(key: key, value: nil)
                stateSubject.send((key, .none))
                startNextJobs()
                return
            }
            pendingJobs.append(next)
            pendingJobKeys.insert(key)
            stateSubject.send((key, .queued))
            startNextJobs()
            return
        }
        // Letzter Versuch ohne Transcoding (Original) — wenn wir bisher mit Format gefragt haben.
        if job.requestedFormat != nil, !job.fellBackToRaw,
           let api = await currentAPI(for: job.serverId),
           let rawURL = api.api.downloadURL(for: job.song.id, server: api.server, password: api.password,
                                            transcoding: nil) {
            if cancelledKeys.contains(key) {
                cancelledKeys.remove(key)
                publishProgress(key: key, value: nil)
                stateSubject.send((key, .none))
                startNextJobs()
                return
            }
            var raw = job
            raw.attempt = 0
            raw.fellBackToRaw = true
            raw.downloadURL = rawURL
            raw.fileExtension = job.song.suffix?.pathSafeFileExtension() ?? "mp3"
            pendingJobs.append(raw)
            pendingJobKeys.insert(key)
            stateSubject.send((key, .queued))
            startNextJobs()
            return
        }
        publishProgress(key: key, value: nil)
        stateSubject.send((key, .failed(message: error.localizedDescription)))
        incrementBatchFailed()
    }

    private func pauseKeepOfflineForStorageFailure(job: DownloadJob, error: Error) async {
        let key = Self.key(songId: job.song.id, serverId: job.serverId)
        DBErrorLog.logPlayLog("DownloadService paused Keep Library Offline because storage is low while downloading \(job.title): \(error.localizedDescription)")
        publishProgress(key: key, value: nil)
        stateSubject.send((key, .failed(message: error.localizedDescription)))
        await MainActor.run {
            KeepLibraryOfflineService.shared.markDownloadStorageFailure(serverId: job.serverId, failedSong: job.song)
        }
        cancelBatch()
    }

    private func isStorageCapacityError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isStorageCapacityError(underlying) {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        return message.contains("no space left")
            || message.contains("not enough space")
            || message.contains("disk full")
            || message.contains("zu wenig speicher")
            || message.contains("nicht genügend speicher")
    }

    // MARK: - Batch Tracking

    private func incrementBatchTotal(by n: Int) {
        batchTotal += n
        publishBatch()
    }

    private func incrementBatchCompleted() {
        batchCompleted += 1
        publishBatch()
        resetBatchIfDone()
    }

    private func incrementBatchFailed() {
        batchFailed += 1
        publishBatch()
        resetBatchIfDone()
    }

    private func resetBatchIfDone() {
        guard pendingJobs.isEmpty, inflightJobs.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.flushBatchIfStillIdle()
        }
    }

    private func flushBatchIfStillIdle() {
        guard pendingJobs.isEmpty, inflightJobs.isEmpty else { return }
        batchTotal = 0
        batchCompleted = 0
        batchFailed = 0
        batchSubject.send(nil)
    }

    private func publishBatch() {
        if batchTotal > 0 {
            batchSubject.send(BatchProgress(total: batchTotal, completed: batchCompleted, failed: batchFailed))
        } else {
            batchSubject.send(nil)
        }
    }

    private func downloadAssetsIfNeeded(for job: DownloadJob, audioPath: String) async {
        let coverPath = Self.coverPath(forFilePath: audioPath)
        if !FileManager.default.fileExists(atPath: coverPath), let coverURL = job.coverURL {
            if let (data, _) = try? await coverSession.data(from: coverURL) {
                try? data.write(to: URL(fileURLWithPath: coverPath), options: .atomic)
            }
        }
        let artDir = Self.artworkDirectory(serverId: job.serverId)
        if let artId = job.artistCoverArtId, let artURL = job.artistCoverURL {
            let artPath = Self.artistCoverPath(serverId: job.serverId, artId: artId)
            if !FileManager.default.fileExists(atPath: artPath) {
                try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                if let (data, _) = try? await coverSession.data(from: artURL) {
                    try? data.write(to: URL(fileURLWithPath: artPath), options: .atomic)
                }
            }
        }
        if let artId = job.albumCoverArtId, let artURL = job.albumCoverURL {
            let artPath = Self.artistCoverPath(serverId: job.serverId, artId: artId)
            if !FileManager.default.fileExists(atPath: artPath) {
                try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                if let (data, _) = try? await coverSession.data(from: artURL) {
                    try? data.write(to: URL(fileURLWithPath: artPath), options: .atomic)
                }
            }
        }
    }

    private func publishProgress(key: String, value: Double?) {
        var current = progressSubject.value
        if let value { current[key] = value } else { current.removeValue(forKey: key) }
        progressSubject.send(current)
    }

    private func notifyLibraryChanged() {
        NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
    }

    // MARK: - Credentials Helpers

    private struct ResolvedAPI {
        let api: SubsonicAPIService
        let server: SubsonicServer
        let password: String
    }

    private func currentAPI(for serverId: String) async -> ResolvedAPI? {
        let api = SubsonicAPIService.shared
        let snapshot: (SubsonicServer?, String?) = await MainActor.run {
            (api.activeServer, api.activePassword)
        }
        guard let server = snapshot.0, server.stableId == serverId,
              let pw = snapshot.1 else { return nil }
        return ResolvedAPI(api: api, server: server, password: pw)
    }

    // MARK: - Paths

    static func rootDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_downloads", isDirectory: true)
    }

    static func serverDirectory(serverId: String) -> URL {
        let safe = serverId.isEmpty ? "_default" : serverId.pathSafeComponent
        return rootDirectory().appendingPathComponent(safe, isDirectory: true)
    }

    static func coverPath(forFilePath audioPath: String) -> String {
        let url = URL(fileURLWithPath: audioPath)
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(stem)_cover.jpg").path
    }

    static func artworkDirectory(serverId: String) -> URL {
        serverDirectory(serverId: serverId).appendingPathComponent("artwork", isDirectory: true)
    }

    static func artistCoverPath(serverId: String, artId: String) -> String {
        artworkDirectory(serverId: serverId).appendingPathComponent("\(artId.pathSafeComponent).jpg").path
    }
}

// MARK: - Coordinator

private final class DownloadSessionCoordinator: NSObject, URLSessionDownloadDelegate {
    nonisolated(unsafe) weak var service: DownloadService?

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        Task { [weak service] in
            await service?.handleProgress(taskIdentifier: id,
                                          written: totalBytesWritten,
                                          total: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let safeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelv-dl-\(id)-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: location, to: safeURL)
        } catch {
            return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: safeURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode
        let mime = http?.mimeType
        let desc = downloadTask.taskDescription
        Task { [weak service] in
            await service?.handleCompletion(taskIdentifier: id, tempURL: safeURL, byteSize: bytes, statusCode: status, mimeType: mime, taskDescription: desc)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard error != nil else { return }
        let id = task.taskIdentifier
        let desc = task.taskDescription
        Task { [weak service] in
            await service?.handleError(taskIdentifier: id, error: error, taskDescription: desc)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        #if os(iOS)
        let identifier = session.configuration.identifier ?? ""
        DispatchQueue.main.async {
            BackgroundDownloadHandler.shared.consume(for: identifier)?()
        }
        #endif
    }
}
