import Foundation
import Combine

extension Notification.Name {
    static let downloadStateChanged = Notification.Name("shelv.downloadStateChanged")
    static let downloadsLibraryChanged = Notification.Name("shelv.downloadsLibraryChanged")
    static let libraryArtistsLoaded = Notification.Name("shelv.libraryArtistsLoaded")
}

private struct DownloadJob {
    let song: Song
    let serverId: String
    var downloadURL: URL
    let coverURL: URL?
    let coverArtId: String?
    let albumCoverArtId: String?
    let albumCoverURL: URL?
    let artistCoverArtId: String?
    let artistCoverURL: URL?
    let albumId: String
    let albumTitle: String
    let artistName: String
    let albumArtistName: String?
    let artistId: String?
    let title: String
    let track: Int?
    let disc: Int?
    let duration: Int?
    var fileExtension: String
    let isFavorite: Bool
    var requestedFormat: TranscodingCodec? = nil
    var fellBackToRaw: Bool = false
    var attempt: Int = 0
    let queuedAt: Date = Date()
}

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

    private let maxConcurrent = 3
    private var effectiveMaxConcurrent: Int {
        TranscodingPolicy.currentDownloadFormat() != nil ? 1 : maxConcurrent
    }
    private let maxAttempts = 3

    private var pendingJobs: [DownloadJob] = []
    private var pendingJobKeys = Set<String>()
    private var inflightJobs: [Int: DownloadJob] = [:]
    private var inflightTasks: [Int: URLSessionTask] = [:]
    private var jobKeyByTask: [Int: String] = [:]
    private var cancelledKeys = Set<String>()
    private var suppressedAlbumIds = Set<String>()
    private var suppressedArtistIds = Set<String>()
    private var suppressedArtistNames = Set<String>()
    private var enqueueEpoch = 0
    private var inCompletionJobs: [String: DownloadJob] = [:]

    nonisolated private let progressSubject = CurrentValueSubject<[String: Double], Never>([:])
    nonisolated private let stateSubject = PassthroughSubject<(key: String, state: DownloadState), Never>()
    nonisolated private let batchSubject = CurrentValueSubject<BatchProgress?, Never>(nil)

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

    private init() {
        coordinator.service = self
    }

    static func key(songId: String, serverId: String) -> String {
        "\(serverId)::\(songId)"
    }

    // MARK: - Setup

    func setup() {
        if session == nil {
            let cfg = URLSessionConfiguration.default
            cfg.allowsCellularAccess = true
            cfg.httpMaximumConnectionsPerHost = maxConcurrent
            session = URLSession(configuration: cfg, delegate: coordinator, delegateQueue: nil)
        }
    }

    // MARK: - Enqueueing

    func enqueue(songs: [Song], serverId: String, albumArtistOverride: String? = nil,
                 albumCoverArtIdOverride: String? = nil) async {
        guard !songs.isEmpty else { return }
        let api = SubsonicAPIService.shared
        guard let cfg = api.currentConfig else { return }
        let downloadedIds = await DownloadDatabase.shared.allSongIds(serverId: serverId)
        let artistCoverById: [String: String] = await MainActor.run {
            Dictionary(LibraryViewModel.shared.artists.compactMap { a in
                a.coverArt.map { (a.name, $0) }
            }, uniquingKeysWith: { first, _ in first })
        }

        // Album-Metadaten vorab fetchen wenn keine Overrides vorliegen, damit
        // Kompilationsalben (z.B. "Various Artists") korrekte albumArtistName und
        // albumCoverArtId erhalten statt dem ersten Track-Künstler/-Cover.
        var albumDetails: [String: (artist: String?, coverArt: String?)] = [:]
        if albumArtistOverride == nil || albumCoverArtIdOverride == nil {
            let neededIds = Set(songs.compactMap { $0.albumId }).filter { !$0.isEmpty }
            await withTaskGroup(of: (String, String?, String?)?.self) { group in
                for albumId in neededIds {
                    group.addTask {
                        guard let detail = try? await api.getAlbum(id: albumId) else { return nil }
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
            cancelledKeys.remove(key)
            let transcoding = TranscodingPolicy.currentDownloadFormat()
            guard let url = api.downloadURL(forConfig: cfg, songId: song.id, transcoding: transcoding) else { continue }
            let cover = song.coverArt.flatMap { api.coverArtURL(forConfig: cfg, id: $0, size: 600) }
            let lookedUp = song.albumId.flatMap { albumDetails[$0] }
            let resolvedAlbumArtist = albumArtistOverride ?? lookedUp?.artist
            let resolvedAlbumCover = albumCoverArtIdOverride ?? lookedUp?.coverArt
            let albumCoverURL: URL? = resolvedAlbumCover.flatMap { api.coverArtURL(forConfig: cfg, id: $0, size: 600) }
            let artistCoverArtId = artistCoverById[resolvedAlbumArtist ?? song.artist ?? ""]
            let artistCoverURL: URL? = artistCoverArtId.flatMap {
                api.coverArtURL(forConfig: cfg, id: $0, size: 600)
            }
            let initialExt: String = {
                if let t = transcoding { return t.codec.fileExtension }
                return (song.suffix?.isEmpty == false) ? song.suffix! : "mp3"
            }()
            let job = DownloadJob(
                song: song,
                serverId: serverId,
                downloadURL: url,
                coverURL: cover,
                coverArtId: song.coverArt,
                albumCoverArtId: resolvedAlbumCover,
                albumCoverURL: albumCoverURL,
                artistCoverArtId: artistCoverArtId,
                artistCoverURL: artistCoverURL,
                albumId: song.albumId ?? "",
                albumTitle: song.album ?? "",
                artistName: song.artist ?? "",
                albumArtistName: resolvedAlbumArtist,
                artistId: song.artistId,
                title: song.title,
                track: song.track,
                disc: song.discNumber,
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
        suppressedAlbumIds.remove(album.id)
        let epoch = enqueueEpoch
        let api = SubsonicAPIService.shared
        do {
            let detail = try await api.getAlbum(id: album.id)
            guard enqueueEpoch == epoch,
                  !suppressedAlbumIds.contains(album.id) else { return }
            if let name = detail.artist, suppressedArtistNames.contains(name) { return }
            let albumArtist = detail.artist ?? album.artist
            let songs = (detail.song ?? []).map { song -> Song in
                if song.artist != nil && song.albumId != nil { return song }
                return Song(
                    id: song.id,
                    title: song.title,
                    artist: song.artist ?? detail.artist,
                    artistId: song.artistId ?? detail.artistId,
                    album: song.album ?? detail.name,
                    albumId: song.albumId ?? detail.id,
                    track: song.track,
                    discNumber: song.discNumber,
                    duration: song.duration,
                    coverArt: song.coverArt ?? detail.coverArt,
                    year: song.year,
                    genre: song.genre,
                    playCount: song.playCount,
                    starred: song.starred,
                    contentType: song.contentType,
                    suffix: song.suffix,
                    bitRate: song.bitRate,
                    replayGain: song.replayGain
                )
            }
            await enqueue(songs: songs, serverId: serverId, albumArtistOverride: albumArtist,
                         albumCoverArtIdOverride: detail.coverArt)
        } catch {
            DBErrorLog.logPlayLog("DownloadService.enqueueAlbum: \(error.localizedDescription)")
        }
    }

    func enqueueArtist(artist: Artist, serverId: String) async {
        suppressedArtistIds.remove(artist.id)
        suppressedArtistNames.remove(artist.name)
        let epoch = enqueueEpoch
        let api = SubsonicAPIService.shared
        do {
            let detail = try await api.getArtist(id: artist.id)
            guard enqueueEpoch == epoch,
                  !suppressedArtistIds.contains(artist.id),
                  !suppressedArtistNames.contains(artist.name) else { return }
            for album in detail.album ?? [] {
                guard enqueueEpoch == epoch,
                      !suppressedArtistIds.contains(artist.id),
                      !suppressedArtistNames.contains(artist.name) else { return }
                await enqueueAlbum(album: album, serverId: serverId)
            }
        } catch {
            DBErrorLog.logPlayLog("DownloadService.enqueueArtist: \(error.localizedDescription)")
        }
    }

    // MARK: - Cancel / Delete

    func cancel(songId: String, serverId: String) {
        let key = Self.key(songId: songId, serverId: serverId)
        cancelledKeys.insert(key)
        let removedPending = pendingJobs.filter { Self.key(songId: $0.song.id, serverId: $0.serverId) == key }.count
        pendingJobs.removeAll { Self.key(songId: $0.song.id, serverId: $0.serverId) == key }
        if removedPending > 0 { pendingJobKeys.remove(key) }
        var removedInflight = 0
        let matchingTaskIds = inflightJobs
            .filter { Self.key(songId: $1.song.id, serverId: $1.serverId) == key }
            .map { $0.key }
        for taskId in matchingTaskIds {
            inflightTasks[taskId]?.cancel()
            inflightTasks.removeValue(forKey: taskId)
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
        suppressedAlbumIds.insert(albumId)
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
        }
        notifyLibraryChanged()
    }

    func deleteArtist(artistId: String, serverId: String) async {
        let isNameKey = artistId.hasPrefix("name:")
        let lookupName = isNameKey ? String(artistId.dropFirst("name:".count)) : artistId

        suppressedArtistIds.insert(artistId)
        suppressedArtistNames.insert(lookupName)
        let artistAlbumIds = Set(
            (pendingJobs + Array(inflightJobs.values)).filter { job in
                guard job.serverId == serverId else { return false }
                if isNameKey { return job.artistName == lookupName }
                return job.artistId == artistId || job.artistName == lookupName
            }.map { $0.albumId }
        )
        suppressedAlbumIds.formUnion(artistAlbumIds)

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
        }
        notifyLibraryChanged()
    }

    private func jobSongIds(matching predicate: (DownloadJob) -> Bool) -> [String] {
        var ids: [String] = []
        ids.append(contentsOf: pendingJobs.filter(predicate).map { $0.song.id })
        ids.append(contentsOf: inflightJobs.values.filter(predicate).map { $0.song.id })
        ids.append(contentsOf: inCompletionJobs.values.filter(predicate).map { $0.song.id })
        return ids
    }

    func cancelBatch() {
        enqueueEpoch += 1
        let pendingKeys = pendingJobs.map { Self.key(songId: $0.song.id, serverId: $0.serverId) }
        pendingJobs.removeAll()
        pendingJobKeys.removeAll()
        let inflightKeys = inflightJobs.values.map { Self.key(songId: $0.song.id, serverId: $0.serverId) }
        for taskId in Array(inflightJobs.keys) {
            inflightTasks[taskId]?.cancel()
            inflightTasks.removeValue(forKey: taskId)
            inflightJobs.removeValue(forKey: taskId)
            jobKeyByTask.removeValue(forKey: taskId)
        }
        let completionKeys = Array(inCompletionJobs.keys)
        for key in completionKeys { cancelledKeys.insert(key) }
        for key in pendingKeys + inflightKeys + completionKeys {
            publishProgress(key: key, value: nil)
            stateSubject.send((key, .none))
        }
        batchTotal = 0; batchCompleted = 0; batchFailed = 0
        batchSubject.send(nil)
    }

    func deleteAllForServer(_ serverId: String) async {
        let records = await DownloadDatabase.shared.allRecords(serverId: serverId)
        for r in records {
            cancel(songId: r.songId, serverId: serverId)
            try? FileManager.default.removeItem(atPath: r.filePath)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: r.filePath))
        }
        await DownloadDatabase.shared.deleteAllForServer(serverId)
        let dir = Self.serverDirectory(serverId: serverId)
        try? FileManager.default.removeItem(at: dir)
        notifyLibraryChanged()
    }

    func deleteAll() async {
        pendingJobs.removeAll()
        pendingJobKeys.removeAll()
        for taskId in Array(inflightJobs.keys) {
            inflightTasks[taskId]?.cancel()
            inflightTasks.removeValue(forKey: taskId)
            inflightJobs.removeValue(forKey: taskId)
            jobKeyByTask.removeValue(forKey: taskId)
        }

        await DownloadDatabase.shared.deleteAll()

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
        let api = SubsonicAPIService.shared
        let alreadyDownloaded = await DownloadDatabase.shared.allSongIds(serverId: serverId)

        // Discover-Listen und alle Album-Songs parallel laden
        async let discoverFreqTask = (try? await api.getAlbumList(type: .frequent, size: 20)) ?? []
        async let discoverRecentTask = (try? await api.getAlbumList(type: .recentlyPlayed, size: 20)) ?? []

        let allSongs: [Song] = await withTaskGroup(of: [Song].self) { group in
            let limit = 10
            var index = 0
            var result: [Song] = []
            for album in libraryAlbums.prefix(limit) {
                group.addTask { (try? await api.getAlbum(id: album.id))?.song ?? [] }
                index += 1
            }
            for await songs in group {
                result.append(contentsOf: songs)
                if index < libraryAlbums.count {
                    let next = libraryAlbums[index]
                    group.addTask { (try? await api.getAlbum(id: next.id))?.song ?? [] }
                    index += 1
                }
            }
            return result
        }

        let discoverFreq = await discoverFreqTask
        let discoverRecent = await discoverRecentTask

        var recapSongIds: [String] = []
        var recapSongsExtra: [Song] = []
        var recapPlaylistSongIdsMap: [String: [String]] = [:]
        if !recapPlaylistIds.isEmpty {
            let fetched: [(String, [Song])] = await withTaskGroup(of: (String, [Song]).self) { group in
                for id in recapPlaylistIds {
                    group.addTask { (id, (try? await api.getPlaylist(id: id))?.songs ?? []) }
                }
                var result: [(String, [Song])] = []
                for await pair in group { result.append(pair) }
                return result
            }
            var seenRecap = Set<String>()
            for (playlistId, songs) in fetched {
                recapPlaylistSongIdsMap[playlistId] = songs.map(\.id)
                for song in songs where seenRecap.insert(song.id).inserted {
                    recapSongIds.append(song.id)
                    recapSongsExtra.append(song)
                }
            }
        }

        // Reihenfolge: Discover (häufig→kürzlich) → Favoriten → Recap → Rest A-Z
        var discoverPriority: [String: Int] = [:]
        for (i, album) in discoverFreq.enumerated() {
            discoverPriority[album.id] = i
        }
        for (i, album) in discoverRecent.enumerated() where discoverPriority[album.id] == nil {
            discoverPriority[album.id] = 100 + i
        }

        let discoverSongs = allSongs
            .compactMap { song -> (id: String, key: Int)? in
                guard let albumId = song.albumId, let pri = discoverPriority[albumId] else { return nil }
                return (song.id, pri * 100 + (song.track ?? 0))
            }
            .sorted { $0.key < $1.key }
            .map(\.id)

        let starred = enabled
            ? allSongs.filter { $0.isStarred }.map(\.id)
            : []

        let alphabetical = allSongs.sorted {
            let a = ($0.artist ?? "").lowercased()
            let b = ($1.artist ?? "").lowercased()
            if a != b { return a < b }
            let aa = ($0.album ?? "").lowercased()
            let bb = ($1.album ?? "").lowercased()
            if aa != bb { return aa < bb }
            return ($0.track ?? 0) < ($1.track ?? 0)
        }.map(\.id)

        var ordered: [String] = []
        var seen = Set<String>()
        func appendUnique(_ ids: [String]) {
            for id in ids where !seen.contains(id) {
                ordered.append(id); seen.insert(id)
            }
        }
        appendUnique(discoverSongs)
        appendUnique(starred)
        appendUnique(recapSongIds)
        appendUnique(alphabetical)

        var songsById = Dictionary(allSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for song in recapSongsExtra where songsById[song.id] == nil {
            songsById[song.id] = song
        }
        let targetBitrate = TranscodingPolicy.currentDownloadFormat()?.bitrate
        var planned: [Song] = []
        var skipped: [Song] = []
        var totalBytes: Int64 = 0
        for songId in ordered {
            guard let song = songsById[songId] else { continue }
            if alreadyDownloaded.contains(song.id) { continue }
            let estBytes = estimatedBytes(for: song, targetBitrate: targetBitrate)
            if totalBytes + estBytes > maxBytes {
                skipped.append(song)
                continue
            }
            planned.append(song)
            totalBytes += estBytes
        }
        return BulkDownloadPlan(planned: planned, skipped: skipped, totalBytes: totalBytes, limitBytes: maxBytes, recapPlaylistSongIds: recapPlaylistSongIdsMap)
    }

    private func estimatedBytes(for song: Song, targetBitrate: Int? = nil) -> Int64 {
        let kbps = targetBitrate ?? song.bitRate ?? 192
        let duration = song.duration ?? 200
        return Int64(kbps) * Int64(duration) * 1024 / 8
    }

    // MARK: - Status

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
        while inflightJobs.count < effectiveMaxConcurrent, !pendingJobs.isEmpty {
            let job = pendingJobs.removeFirst()
            let jobKey = Self.key(songId: job.song.id, serverId: job.serverId)
            pendingJobKeys.remove(jobKey)
            let task = session.downloadTask(with: job.downloadURL)
            inflightJobs[task.taskIdentifier] = job
            inflightTasks[task.taskIdentifier] = task
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

    func handleCompletion(taskIdentifier: Int, tempURL: URL, byteSize: Int64, mimeType: String?) async {
        guard let job = inflightJobs[taskIdentifier] else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        inflightJobs.removeValue(forKey: taskIdentifier)
        inflightTasks.removeValue(forKey: taskIdentifier)
        jobKeyByTask.removeValue(forKey: taskIdentifier)

        let key = Self.key(songId: job.song.id, serverId: job.serverId)
        inCompletionJobs[key] = job
        defer { inCompletionJobs.removeValue(forKey: key) }

        let serverDir = Self.serverDirectory(serverId: job.serverId)
        let actualExt = await MainActor.run { TranscodingPolicy.extensionFor(mimeType: mimeType) } ?? job.fileExtension
        let finalURL = serverDir.appendingPathComponent("\(job.song.id).\(actualExt)")

        if cancelledKeys.contains(key) {
            cancelledKeys.remove(key)
            try? FileManager.default.removeItem(at: tempURL)
            publishProgress(key: key, value: nil)
            stateSubject.send((key, .none))
            return
        }

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
            albumArtistName: job.albumArtistName,
            albumCoverArtId: job.albumCoverArtId,
            track: job.track,
            disc: job.disc,
            duration: job.duration,
            bytes: bytes,
            coverArtId: job.coverArtId,
            artistCoverArtId: job.artistCoverArtId,
            isFavorite: job.isFavorite,
            filePath: finalURL.path,
            fileExtension: actualExt,
            addedAt: Date().timeIntervalSince1970
        )
        await DownloadDatabase.shared.upsert(record)

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

    func handleError(taskIdentifier: Int, error: Error?) async {
        guard let job = inflightJobs.removeValue(forKey: taskIdentifier) else {
            jobKeyByTask.removeValue(forKey: taskIdentifier)
            return
        }
        jobKeyByTask.removeValue(forKey: taskIdentifier)
        await retryOrFail(job: job, error: error ?? NSError(domain: "DownloadService", code: 0))
    }

    private func retryOrFail(job: DownloadJob, error: Error) async {
        let key = Self.key(songId: job.song.id, serverId: job.serverId)
        let epoch = enqueueEpoch
        var next = job
        next.attempt += 1
        if next.attempt < maxAttempts {
            let backoff = pow(2.0, Double(next.attempt))
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard enqueueEpoch == epoch else { return }
            pendingJobs.append(next)
            pendingJobKeys.insert(key)
            stateSubject.send((key, .queued))
            startNextJobs()
            return
        }
        // Letzter Versuch ohne Transcoding (Original)
        if job.requestedFormat != nil, !job.fellBackToRaw,
           let cfg = SubsonicAPIService.shared.currentConfig,
           let rawURL = SubsonicAPIService.shared.downloadURL(forConfig: cfg, songId: job.song.id, transcoding: nil) {
            var raw = job
            raw.attempt = 0
            raw.fellBackToRaw = true
            raw.downloadURL = rawURL
            raw.fileExtension = (job.song.suffix?.isEmpty == false) ? job.song.suffix! : "mp3"
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
        batchTotal = 0; batchCompleted = 0; batchFailed = 0
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
        if let artId = job.albumCoverArtId, let artURL = job.albumCoverURL {
            let artPath = Self.artistCoverPath(serverId: job.serverId, artId: artId)
            if !FileManager.default.fileExists(atPath: artPath) {
                try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                if let (data, _) = try? await coverSession.data(from: artURL) {
                    try? data.write(to: URL(fileURLWithPath: artPath), options: .atomic)
                    await LocalArtworkIndex.shared.set(artId: artId, path: artPath)
                }
            }
        }
        if let artId = job.artistCoverArtId, let artURL = job.artistCoverURL {
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
        Task { @MainActor in
            NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
        }
    }

    // MARK: - Paths

    static func rootDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_downloads", isDirectory: true)
    }

    static func serverDirectory(serverId: String) -> URL {
        let safe = serverId.isEmpty ? "_default" : serverId
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
        artworkDirectory(serverId: serverId).appendingPathComponent("\(artId).jpg").path
    }
}

private final class DownloadSessionCoordinator: NSObject, URLSessionDownloadDelegate {
    weak var service: DownloadService?

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
        let mime = (downloadTask.response as? HTTPURLResponse)?.mimeType
        Task { [weak service] in
            await service?.handleCompletion(taskIdentifier: id, tempURL: safeURL, byteSize: bytes, mimeType: mime)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard error != nil else { return }
        let id = task.taskIdentifier
        Task { [weak service] in
            await service?.handleError(taskIdentifier: id, error: error)
        }
    }
}
