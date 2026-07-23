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

private nonisolated struct DownloadJob: Codable, Sendable {
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
    let albumMarker: BulkDownloadAlbumMarker?
}

private nonisolated struct DownloadCollectionRefresh: Sendable {
    let kind: DownloadCollectionKind
    let id: String
    let serverId: String
    let signature: String

    var key: String { "\(serverId)::\(kind.rawValue)::\(id)" }
}

private actor DownloadArtworkPipeline {
    // Match the existing audio concurrency so artwork deduplication does not
    // delay the visible completion of an otherwise finished batch.
    private static let maxConcurrentRequests = 5
    private let session: URLSession
    private var activeRequests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlightByKey: [String: Task<Data?, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = Self.maxConcurrentRequests
        session = URLSession(configuration: configuration)
    }

    func data(for key: String, url: URL) async -> Data? {
        if let task = inFlightByKey[key] {
            return await task.value
        }

        let task = Task { [weak self] in
            await self?.download(url: url)
        }
        inFlightByKey[key] = task
        let data = await task.value
        inFlightByKey.removeValue(forKey: key)
        return data
    }

    private func download(url: URL) async -> Data? {
        await acquireSlot()
        defer { releaseSlot() }
        return try? await session.data(from: url).0
    }

    private func acquireSlot() async {
        if activeRequests < Self.maxConcurrentRequests {
            activeRequests += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeRequests = max(0, activeRequests - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - DownloadService

actor DownloadService {
    static let shared = DownloadService()

    private let coordinator = DownloadSessionCoordinator()
    private var session: URLSession?
    private let artworkPipeline = DownloadArtworkPipeline()

    private let backgroundIdentifier = "ch.vkugler.Shelv.downloads"
    private let maxConcurrent = 5
    private let queuedStatePublishLimit = 500
    private var effectiveMaxConcurrent: Int {
        TranscodingPolicy.currentDownloadFormat() != nil ? 1 : maxConcurrent
    }
    private let maxAttempts = 3

    private var pendingJobs: [DownloadJob] = []
    private var pendingJobStartIndex = 0
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
    // Fehlgeschlagene Jobs bleiben auch während Retry-Backoff und asynchroner
    // Fallback-Vorbereitung sichtbar und zuverlässig abbrechbar.
    private var retryingJobs = DownloadRetryRegistry<DownloadJob>()

    nonisolated(unsafe) private let progressSubject = CurrentValueSubject<[String: Double], Never>([:])
    nonisolated(unsafe) private let stateSubject = PassthroughSubject<(key: String, state: DownloadState), Never>()
    nonisolated(unsafe) private let batchSubject = CurrentValueSubject<BatchProgress?, Never>(nil)

    // URLSession may report progress many times per second. Keep live values actor-owned,
    // then publish one changed snapshot per UI interval instead of every callback.
    private let progressPublishIntervalNanoseconds: UInt64 = 200_000_000
    private var currentProgress: [String: Double] = [:]
    private var lastPublishedProgress: [String: Double] = [:]
    private var progressPublishTask: Task<Void, Never>?
    private var progressPublishGeneration: UInt64 = 0

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
    private var metadataReloadTask: Task<Void, Never>?
    private var collectionRefreshQueue: [DownloadCollectionRefresh] = []
    private var collectionRefreshStartIndex = 0
    private var queuedCollectionRefreshKeys = Set<String>()
    private var activeCollectionRefreshKeys = Set<String>()
    private let maxConcurrentCollectionRefreshes = 2
    private let staleCollectionRefreshInterval: TimeInterval = 24 * 60 * 60
    private let staleAlbumRefreshLimitPerObservation = 12

    private init() {
        coordinator.service = self
    }

    static func key(songId: String, serverId: String) -> String {
        "\(serverId)::\(songId)"
    }

    private var hasPendingJobs: Bool {
        pendingJobStartIndex < pendingJobs.count
    }

    private var activePendingJobs: ArraySlice<DownloadJob> {
        guard hasPendingJobs else { return [] }
        return pendingJobs[pendingJobStartIndex...]
    }

    private var hasTrackedJobs: Bool {
        hasPendingJobs
            || !inflightJobs.isEmpty
            || !inCompletionJobs.isEmpty
            || !retryingJobs.isEmpty
    }

    private func appendPendingJob(_ job: DownloadJob) {
        pendingJobs.append(job)
    }

    private func popNextPendingJob() -> DownloadJob? {
        guard hasPendingJobs else {
            clearPendingJobs(keepingCapacity: true)
            return nil
        }
        let job = pendingJobs[pendingJobStartIndex]
        pendingJobStartIndex += 1
        compactPendingJobsIfNeeded()
        return job
    }

    private func removePendingJobs(where shouldRemove: (DownloadJob) -> Bool) -> Int {
        compactPendingJobs(force: true)
        let before = pendingJobs.count
        pendingJobs.removeAll(where: shouldRemove)
        return before - pendingJobs.count
    }

    private func clearPendingJobs(keepingCapacity: Bool = false) {
        pendingJobs.removeAll(keepingCapacity: keepingCapacity)
        pendingJobStartIndex = 0
    }

    private func compactPendingJobsIfNeeded() {
        if pendingJobStartIndex == pendingJobs.count {
            clearPendingJobs(keepingCapacity: true)
        } else if pendingJobStartIndex > 512 && pendingJobStartIndex * 2 > pendingJobs.count {
            compactPendingJobs(force: true)
        }
    }

    private func compactPendingJobs(force: Bool = false) {
        guard pendingJobStartIndex > 0, (force || pendingJobStartIndex * 2 > pendingJobs.count) else { return }
        pendingJobs.removeFirst(pendingJobStartIndex)
        pendingJobStartIndex = 0
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
            cfg.allowsExpensiveNetworkAccess = true
            cfg.allowsConstrainedNetworkAccess = true
            cfg.networkServiceType = .responsiveData
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

    // MARK: - Download Catalog Reconciliation

    private nonisolated static func downloadAlbumMetadata(
        from detail: AlbumDetail
    ) -> DownloadAlbumMetadata {
        DownloadAlbumMetadata(
            id: detail.id,
            name: detail.name,
            artist: detail.artist,
            artistId: detail.artistId,
            coverArt: detail.coverArt,
            songCount: detail.songCount,
            duration: detail.duration,
            year: detail.year,
            genre: detail.genre
        )
    }

    func observeAlbumSummaries(
        _ albums: [Album],
        serverId: String,
        schedulesStaleRefresh: Bool = false
    ) async {
        #if os(tvOS)
        return
        #else
        guard !serverId.isEmpty, !albums.isEmpty else { return }
        let metadataUpdate = await DownloadDatabase.shared.updateAlbumSummaries(
            albums,
            serverId: serverId
        )
        handleMetadataUpdate(metadataUpdate)

        var managedIds = await DownloadDatabase.shared.managedAlbumIds(serverId: serverId)
        managedIds = await adoptCompleteAlbumDownloads(
            from: albums,
            serverId: serverId,
            managedIds: managedIds
        )

        for album in albums where managedIds.contains(album.id) {
            await DownloadDatabase.shared.markAlbumDownloaded(
                id: album.id,
                name: album.name,
                serverId: serverId
            )
        }

        let observations = albums.map {
            DownloadCollectionObservation(
                id: $0.id,
                signature: DownloadDatabase.albumSignature($0)
            )
        }
        let staleBefore = schedulesStaleRefresh
            ? Date().timeIntervalSince1970 - staleCollectionRefreshInterval
            : nil
        let candidates = await DownloadDatabase.shared.collectionRefreshCandidates(
            kind: .album,
            observations: observations,
            serverId: serverId,
            managedIds: managedIds,
            staleBefore: staleBefore,
            staleLimit: schedulesStaleRefresh ? staleAlbumRefreshLimitPerObservation : 0
        )
        let signaturesByID = Dictionary(
            observations.map { ($0.id, $0.signature) },
            uniquingKeysWith: { first, _ in first }
        )
        enqueueCollectionRefreshes(
            candidates.compactMap { id in
                signaturesByID[id].map {
                    DownloadCollectionRefresh(
                        kind: .album,
                        id: id,
                        serverId: serverId,
                        signature: $0
                    )
                }
            },
            limit: staleAlbumRefreshLimitPerObservation
        )
        #endif
    }

    func adoptCachedAlbumDownloads(_ albums: [Album], serverId: String) async {
        #if os(tvOS)
        return
        #else
        guard !serverId.isEmpty, !albums.isEmpty else { return }
        let managedIds = await DownloadDatabase.shared.managedAlbumIds(
            serverId: serverId
        )
        _ = await adoptCompleteAlbumDownloads(
            from: albums,
            serverId: serverId,
            managedIds: managedIds
        )
        #endif
    }

    private func adoptCompleteAlbumDownloads(
        from albums: [Album],
        serverId: String,
        managedIds: Set<String>
    ) async -> Set<String> {
        let albumsByID = Dictionary(
            albums.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let records = await DownloadDatabase.shared.records(
            serverId: serverId,
            albumIds: Set(albumsByID.keys)
        )
        let recordsByAlbum = Dictionary(
            grouping: records.filter { !$0.albumId.isEmpty },
            by: \.albumId
        )
        let playlistOwnedSongIds = Set(
            LocalOfflinePlaylistCatalog.songIds(serverId: serverId)
                .values
                .flatMap { $0 }
        )
        var adoptedIds = managedIds

        // Existing installations did not persist whether an album was downloaded
        // as a complete collection. The cached pre-refresh song count lets us
        // retain that intent even when the server has just added another song.
        for (albumID, albumRecords) in recordsByAlbum {
            guard !adoptedIds.contains(albumID),
                  let album = albumsByID[albumID],
                  let expectedSongCount = album.songCount,
                  expectedSongCount > 0,
                  expectedSongCount == albumRecords.count,
                  albumRecords.contains(where: {
                      !playlistOwnedSongIds.contains($0.songId)
                  })
            else { continue }
            await DownloadDatabase.shared.markAlbumDownloaded(
                id: albumID,
                name: album.name,
                serverId: serverId
            )
            await DownloadDatabase.shared.noteCollectionDetail(
                kind: .album,
                id: albumID,
                serverId: serverId,
                signature: DownloadDatabase.albumSignature(album),
                date: 0
            )
            adoptedIds.insert(albumID)
        }
        return adoptedIds
    }

    func observeArtistSummaries(_ artists: [Artist], serverId: String) async {
        #if os(tvOS)
        return
        #else
        guard !serverId.isEmpty, !artists.isEmpty else { return }
        let update = await DownloadDatabase.shared.updateArtistSummaries(
            artists,
            serverId: serverId
        )
        handleMetadataUpdate(update)
        #endif
    }

    func observeSongs(_ songs: [Song], serverId: String) async {
        #if os(tvOS)
        return
        #else
        guard !serverId.isEmpty, !songs.isEmpty else { return }
        let update = await DownloadDatabase.shared.updateObservedSongs(
            songs,
            serverId: serverId
        )
        handleMetadataUpdate(update)
        #endif
    }

    func observeAlbumDetail(_ detail: AlbumDetail, serverId: String) async {
        #if os(tvOS)
        return
        #else
        guard !serverId.isEmpty else { return }
        let albumMetadata = Self.downloadAlbumMetadata(from: detail)
        let summary = Album(
            id: detail.id,
            name: detail.name,
            sortName: detail.sortName,
            artist: detail.artist,
            artistId: detail.artistId,
            coverArt: detail.coverArt,
            songCount: detail.songCount,
            duration: detail.duration,
            year: detail.year,
            genre: detail.genre
        )
        handleMetadataUpdate(
            await DownloadDatabase.shared.updateAlbumSummaries(
                [summary],
                serverId: serverId
            )
        )

        guard let songs = detail.song else { return }
        let localRecords = await DownloadDatabase.shared.records(
            serverId: serverId,
            albumId: detail.id
        )
        handleMetadataUpdate(
            await DownloadDatabase.shared.updateObservedSongs(
                songs,
                serverId: serverId,
                albumMetadata: albumMetadata
            )
        )

        let managedAlbumIds = await DownloadDatabase.shared.managedAlbumIds(
            serverId: serverId
        )
        var isManaged = managedAlbumIds.contains(detail.id)
        if !isManaged, !localRecords.isEmpty {
            let playlistOwnedSongIds = Set(
                LocalOfflinePlaylistCatalog.songIds(serverId: serverId)
                    .values
                    .flatMap { $0 }
            )
            let localSongIds = Set(localRecords.map(\.songId))
            let serverSongIds = Set(songs.map(\.id))
            if localSongIds == serverSongIds,
               localRecords.contains(where: {
                   !playlistOwnedSongIds.contains($0.songId)
               }) {
                await DownloadDatabase.shared.markAlbumDownloaded(
                    id: detail.id,
                    name: detail.name,
                    serverId: serverId
                )
                isManaged = true
            }
        }

        if isManaged {
            let localSongIds = Set(localRecords.map(\.songId))
            let reconciliation = DownloadAlbumMembershipReconciliation.make(
                localSongIDs: localSongIds,
                serverSongs: songs
            )
            for songID in reconciliation.removedSongIDs {
                await delete(
                    songId: songID,
                    serverId: serverId,
                    preservesManagedAlbum: true
                )
            }

            if !reconciliation.missingSongs.isEmpty,
               await canMaintainDownloads(serverId: serverId) {
                await enqueue(
                    songs: reconciliation.missingSongs,
                    serverId: serverId,
                    albumArtistOverride: detail.artist,
                    albumCoverArtIdOverride: detail.coverArt,
                    resolvesAlbumMetadata: false
                )
            }
            await DownloadDatabase.shared.noteCollectionDetail(
                kind: .album,
                id: detail.id,
                serverId: serverId,
                signature: DownloadDatabase.albumSignature(albumMetadata)
            )
        }
        #endif
    }

    func observePlaylistSummaries(
        _ playlists: [Playlist],
        serverId: String
    ) async {
        #if os(tvOS)
        return
        #else
        guard !serverId.isEmpty, !playlists.isEmpty else { return }
        let tracked = LocalOfflinePlaylistCatalog.songIds(serverId: serverId)
        let managedIds = Set(tracked.keys)
        guard !managedIds.isEmpty else { return }

        for playlist in playlists where managedIds.contains(playlist.id) {
            await LocalOfflinePlaylistCatalog.updateName(
                serverId: serverId,
                id: playlist.id,
                name: playlist.name
            )
        }
        let observations = playlists.map {
            DownloadCollectionObservation(
                id: $0.id,
                signature: DownloadDatabase.playlistSignature($0)
            )
        }
        let candidates = await DownloadDatabase.shared.collectionRefreshCandidates(
            kind: .playlist,
            observations: observations,
            serverId: serverId,
            managedIds: managedIds,
            staleBefore: nil,
            staleLimit: 0
        )
        let signaturesByID = Dictionary(
            observations.map { ($0.id, $0.signature) },
            uniquingKeysWith: { first, _ in first }
        )
        enqueueCollectionRefreshes(
            candidates.compactMap { id in
                signaturesByID[id].map {
                    DownloadCollectionRefresh(
                        kind: .playlist,
                        id: id,
                        serverId: serverId,
                        signature: $0
                    )
                }
            },
            limit: 12
        )
        #endif
    }

    func observePlaylistDetail(_ playlist: Playlist, serverId: String) async {
        #if os(tvOS)
        return
        #else
        guard !serverId.isEmpty, let songs = playlist.songs else { return }
        await observeSongs(songs, serverId: serverId)
        let tracked = LocalOfflinePlaylistCatalog.songIds(serverId: serverId)
        guard tracked[playlist.id] != nil else { return }

        let serverSongIds = songs.map(\.id)
        LocalOfflinePlaylistCatalog.updateSongIds(
            serverId: serverId,
            id: playlist.id,
            songIds: serverSongIds
        )
        if SubsonicAPIService.shared.activeServer?.stableId == serverId {
            await MainActor.run {
                DownloadStore.shared.syncPlaylistSongIds(
                    playlist.id,
                    songIds: serverSongIds
                )
            }
        }
        if await canMaintainDownloads(serverId: serverId) {
            let downloadedIds = await DownloadDatabase.shared.allSongIds(serverId: serverId)
            let missing = songs.filter { !downloadedIds.contains($0.id) }
            if !missing.isEmpty {
                Task { [weak self] in
                    await self?.enqueue(
                        songs: missing,
                        serverId: serverId
                    )
                }
            }
        }
        await DownloadDatabase.shared.noteCollectionDetail(
            kind: .playlist,
            id: playlist.id,
            serverId: serverId,
            signature: DownloadDatabase.playlistSignature(playlist)
        )
        #endif
    }

    private func canMaintainDownloads(serverId: String) async -> Bool {
        await MainActor.run {
            !OfflineModeService.shared.isOffline
                && OfflineModeService.shared.downloadsFeatureEnabled
                && !KeepLibraryOfflineService.shared.isEnabled(serverId: serverId)
        }
    }

    private func handleMetadataUpdate(_ update: DownloadMetadataUpdate) {
        guard !update.isEmpty else { return }
        guard let serverId = update.changes.first?.updated.serverId,
              SubsonicAPIService.shared.activeServer?.stableId == serverId
        else { return }
        scheduleMetadataReload()
        let artworkChanges = update.changes.filter {
            $0.previous.coverArtId != $0.updated.coverArtId
                || $0.previous.albumCoverArtId != $0.updated.albumCoverArtId
                || $0.previous.artistCoverArtId != $0.updated.artistCoverArtId
        }
        guard !artworkChanges.isEmpty else { return }
        for change in artworkChanges
            where change.previous.coverArtId != change.updated.coverArtId {
            let path = Self.coverPath(forFilePath: change.updated.filePath)
            LocalArtworkIndex.shared.remove(path: path)
            try? FileManager.default.removeItem(atPath: path)
        }
        Task { [weak self] in
            await self?.refreshArtwork(for: artworkChanges)
        }
    }

    private func scheduleMetadataReload() {
        guard metadataReloadTask == nil else { return }
        metadataReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.performMetadataReload()
        }
    }

    private func performMetadataReload() async {
        metadataReloadTask = nil
        #if !os(tvOS)
        await DownloadStore.shared.reload()
        #endif
    }

    private func refreshArtwork(
        for changes: [DownloadRecordMetadataChange]
    ) async {
        guard let serverId = changes.first?.updated.serverId,
              let api = await currentAPI(for: serverId)
        else { return }

        for change in changes {
            let record = change.updated
            if change.previous.coverArtId != record.coverArtId,
               let artId = record.coverArtId,
               let url = api.api.coverArtURL(
                   for: artId,
                   server: api.server,
                   password: api.password,
                   size: 600
               ),
               let sharedPath = await ensureSharedArtwork(
                   artId: artId,
                   url: url,
                   serverId: serverId
               ) {
                let destination = Self.coverPath(forFilePath: record.filePath)
                try? FileManager.default.removeItem(atPath: destination)
                do {
                    try FileManager.default.linkItem(
                        atPath: sharedPath,
                        toPath: destination
                    )
                } catch {
                    try? FileManager.default.copyItem(
                        atPath: sharedPath,
                        toPath: destination
                    )
                }
                if FileManager.default.fileExists(atPath: destination) {
                    LocalArtworkIndex.shared.set(artId: artId, path: destination)
                }
            }
            if change.previous.albumCoverArtId != record.albumCoverArtId,
               let artId = record.albumCoverArtId,
               let url = api.api.coverArtURL(
                   for: artId,
                   server: api.server,
                   password: api.password,
                   size: 600
               ) {
                _ = await ensureSharedArtwork(
                    artId: artId,
                    url: url,
                    serverId: serverId
                )
            }
            if change.previous.artistCoverArtId != record.artistCoverArtId,
               let artId = record.artistCoverArtId,
               let url = api.api.coverArtURL(
                   for: artId,
                   server: api.server,
                   password: api.password,
                   size: 600
               ) {
                _ = await ensureSharedArtwork(
                    artId: artId,
                    url: url,
                    serverId: serverId
                )
            }
        }
        NotificationCenter.default.post(name: .artworkIndexReady, object: nil)
    }

    private func enqueueCollectionRefreshes(
        _ refreshes: [DownloadCollectionRefresh],
        limit: Int
    ) {
        var added = 0
        for refresh in refreshes {
            guard !queuedCollectionRefreshKeys.contains(refresh.key),
                  !activeCollectionRefreshKeys.contains(refresh.key)
            else { continue }
            guard added < limit else { break }
            collectionRefreshQueue.append(refresh)
            queuedCollectionRefreshKeys.insert(refresh.key)
            added += 1
        }
        startNextCollectionRefreshes()
    }

    private func startNextCollectionRefreshes() {
        while activeCollectionRefreshKeys.count < maxConcurrentCollectionRefreshes,
              collectionRefreshStartIndex < collectionRefreshQueue.count {
            let refresh = collectionRefreshQueue[collectionRefreshStartIndex]
            collectionRefreshStartIndex += 1
            queuedCollectionRefreshKeys.remove(refresh.key)
            activeCollectionRefreshKeys.insert(refresh.key)
            Task { [weak self] in
                await self?.performCollectionRefresh(refresh)
                await self?.finishCollectionRefresh(refresh)
            }
        }
        compactCollectionRefreshQueueIfNeeded()
    }

    private func performCollectionRefresh(
        _ refresh: DownloadCollectionRefresh
    ) async {
        guard SubsonicAPIService.shared.activeServer?.stableId == refresh.serverId
        else { return }
        let isOffline = await MainActor.run {
            OfflineModeService.shared.isOffline
        }
        guard !isOffline else { return }
        do {
            let api = SubsonicAPIService.shared
            let context = try await api.resolvedActiveRequestContext(
                expectedServerId: refresh.serverId
            )
            switch refresh.kind {
            case .album:
                _ = try await api.getAlbum(
                    id: refresh.id,
                    context: context
                )
            case .playlist:
                _ = try await api.getPlaylist(
                    id: refresh.id,
                    context: context
                )
            }
            await DownloadDatabase.shared.noteCollectionDetail(
                kind: refresh.kind,
                id: refresh.id,
                serverId: refresh.serverId,
                signature: refresh.signature
            )
        } catch {
            return
        }
    }

    private func finishCollectionRefresh(_ refresh: DownloadCollectionRefresh) {
        activeCollectionRefreshKeys.remove(refresh.key)
        startNextCollectionRefreshes()
    }

    private func compactCollectionRefreshQueueIfNeeded() {
        guard collectionRefreshStartIndex > 64,
              collectionRefreshStartIndex * 2 >= collectionRefreshQueue.count
        else { return }
        collectionRefreshQueue.removeFirst(collectionRefreshStartIndex)
        collectionRefreshStartIndex = 0
    }

    // MARK: - Enqueueing

    func enqueue(
        songs: [Song],
        serverId: String,
        albumArtistOverride: String? = nil,
        albumCoverArtIdOverride: String? = nil,
        managedAlbumMarkers: [BulkDownloadAlbumMarker] = [],
        resolvesAlbumMetadata: Bool = true,
        requiresKeepLibraryOfflineEnabled: Bool = false
    ) async {
        guard await canStartDownloads() else { return }
        for marker in managedAlbumMarkers {
            await DownloadDatabase.shared.markAlbumDownloaded(
                id: marker.id,
                name: marker.name,
                serverId: serverId
            )
        }
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
        if resolvesAlbumMetadata
            && (albumArtistOverride == nil || albumCoverArtIdOverride == nil) {
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

        if requiresKeepLibraryOfflineEnabled {
            let canContinue = await MainActor.run {
                KeepLibraryOfflineService.shared.isEnqueueAuthorized(serverId: serverId)
            }
            guard canContinue else { return }
        }

        let transcoding = TranscodingPolicy.currentDownloadFormat()
        let shouldPublishQueuedStates = songs.count <= queuedStatePublishLimit
        var added = 0
        for song in songs {
            let key = Self.key(songId: song.id, serverId: serverId)
            if downloadedIds.contains(song.id) { continue }
            if inflightJobs.values.contains(where: { Self.key(songId: $0.song.id, serverId: $0.serverId) == key }) { continue }
            if pendingJobKeys.contains(key) { continue }
            if retryingJobs.contains(key) { continue }
            // Stale Cancel-Marker beim Neu-Enqueue entfernen — sonst würde eine spätere
            // Completion fälschlich als "cancelled" interpretiert.
            cancelledKeys.remove(key)
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
            appendPendingJob(job)
            pendingJobKeys.insert(key)
            if shouldPublishQueuedStates {
                stateSubject.send((key, .queued))
            }
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
            await DownloadDatabase.shared.markAlbumDownloaded(
                id: detail.id,
                name: detail.name,
                serverId: serverId
            )
            await DownloadDatabase.shared.noteCollectionDetail(
                kind: .album,
                id: detail.id,
                serverId: serverId,
                signature: DownloadDatabase.albumSignature(
                    Self.downloadAlbumMetadata(from: detail)
                )
            )
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
        let isFirstCancellation = cancelledKeys.insert(key).inserted
        let removedPending = removePendingJobs { Self.key(songId: $0.song.id, serverId: $0.serverId) == key }
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
        let removedRetrying = retryingJobs.removeValue(forKey: key) != nil
        let wasTracked = removedPending > 0 || removedInflight > 0 || inCompletion > 0 || removedRetrying
        if wasTracked && isFirstCancellation {
            batchTotal = max(0, batchTotal - 1)
            publishBatch()
            resetBatchIfDone()
        }
        if removedRetrying { startNextJobs() }
    }

    func delete(
        songId: String,
        serverId: String,
        preservesManagedAlbum: Bool = false
    ) async {
        cancel(songId: songId, serverId: serverId)
        let record = await DownloadDatabase.shared.record(
            songId: songId,
            serverId: serverId
        )
        if let path = await DownloadDatabase.shared.filePath(songId: songId, serverId: serverId) {
            LocalArtworkIndex.shared.remove(path: Self.coverPath(forFilePath: path))
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: path))
        }
        await DownloadDatabase.shared.delete(songId: songId, serverId: serverId)
        if !preservesManagedAlbum, let albumId = record?.albumId, !albumId.isEmpty {
            await DownloadDatabase.shared.unmarkAlbumDownloaded(
                id: albumId,
                serverId: serverId
            )
        }
        let key = Self.key(songId: songId, serverId: serverId)
        stateSubject.send((key, .none))
        await DownloadStore.shared.removeRecord(songId: songId, serverId: serverId)
    }

    func deleteAlbum(albumId: String, serverId: String) async {
        await DownloadDatabase.shared.unmarkAlbumDownloaded(
            id: albumId,
            serverId: serverId
        )
        let queuedSongIds = jobSongIds(matching: { $0.albumId == albumId && $0.serverId == serverId })
        for songId in queuedSongIds { cancel(songId: songId, serverId: serverId) }

        let records = await DownloadDatabase.shared.allRecords(serverId: serverId)
            .filter { $0.albumId == albumId }
        for r in records {
            cancel(songId: r.songId, serverId: serverId)
            LocalArtworkIndex.shared.remove(path: Self.coverPath(forFilePath: r.filePath))
            try? FileManager.default.removeItem(atPath: r.filePath)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: r.filePath))
            await DownloadDatabase.shared.delete(songId: r.songId, serverId: serverId)
            stateSubject.send((Self.key(songId: r.songId, serverId: serverId), .none))
            await DownloadStore.shared.removeRecord(songId: r.songId, serverId: serverId)
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
        for albumId in Set(records.map(\.albumId)).filter({ !$0.isEmpty }) {
            await DownloadDatabase.shared.unmarkAlbumDownloaded(
                id: albumId,
                serverId: serverId
            )
        }
        for r in records {
            cancel(songId: r.songId, serverId: serverId)
            LocalArtworkIndex.shared.remove(path: Self.coverPath(forFilePath: r.filePath))
            try? FileManager.default.removeItem(atPath: r.filePath)
            try? FileManager.default.removeItem(atPath: Self.coverPath(forFilePath: r.filePath))
            await DownloadDatabase.shared.delete(songId: r.songId, serverId: serverId)
            stateSubject.send((Self.key(songId: r.songId, serverId: serverId), .none))
            await DownloadStore.shared.removeRecord(songId: r.songId, serverId: serverId)
        }
    }

    private func jobSongIds(matching predicate: (DownloadJob) -> Bool) -> [String] {
        var ids = Set<String>()
        ids.formUnion(activePendingJobs.filter(predicate).map { $0.song.id })
        ids.formUnion(inflightJobs.values.filter(predicate).map { $0.song.id })
        ids.formUnion(inCompletionJobs.values.filter(predicate).map { $0.song.id })
        ids.formUnion(retryingJobs.jobs.filter(predicate).map { $0.song.id })
        return Array(ids)
    }

    func cancelBatch() {
        let pendingKeys = activePendingJobs.map { Self.key(songId: $0.song.id, serverId: $0.serverId) }
        clearPendingJobs(keepingCapacity: true)
        pendingJobKeys.removeAll()
        let inflightKeys = inflightJobs.values.map { Self.key(songId: $0.song.id, serverId: $0.serverId) }
        for taskId in Array(inflightJobs.keys) {
            inflightJobs.removeValue(forKey: taskId)
            jobKeyByTask.removeValue(forKey: taskId)
        }
        let completionKeys = Array(inCompletionJobs.keys)
        let retryingKeys = retryingJobs.keys
        retryingJobs.removeAll(keepingCapacity: true)
        let activeKeys = Set(pendingKeys + inflightKeys + completionKeys + retryingKeys)
        for key in activeKeys { cancelledKeys.insert(key) }
        session?.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        for key in activeKeys {
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
            LocalArtworkIndex.shared.remove(path: Self.coverPath(forFilePath: r.filePath))
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

        clearProgress()
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

        async let discoverFreqTask = (try? await apiService.getAlbumList(
            type: "frequent",
            size: 20
        )) ?? []
        async let discoverRecentTask = (try? await apiService.getAlbumList(
            type: "recent",
            size: 20
        )) ?? []
        async let discoverNewestTask = (try? await apiService.getAlbumList(
            type: "newest",
            size: 50
        )) ?? []
        async let albumPairsTask = fetchAlbumSongPairs(api: apiService, albums: libraryAlbums)
        async let playlistPairsTask = fetchPlaylistSongPairs(api: apiService, recapPlaylistIds: recapPlaylistIds)

        let discoverFreq = await discoverFreqTask
        let discoverRecent = await discoverRecentTask
        let discoverNewest = await discoverNewestTask
        let albumPairs = await albumPairsTask
        let playlistPairs = await playlistPairsTask

        let albumSongsById = Dictionary(albumPairs.map { ($0.album.id, sortAlbumSongs($0.songs)) },
                                        uniquingKeysWith: { first, _ in first })
        let libraryAlbumsById = Dictionary(
            libraryAlbums.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

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
                playlistMarker: nil,
                albumMarker: BulkDownloadAlbumMarker(
                    id: albumId,
                    name: libraryAlbumsById[albumId]?.name
                        ?? songs.first?.album
                        ?? "",
                    songIds: songs.map(\.id)
                )
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
                ),
                albumMarker: nil
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
                ),
                albumMarker: nil
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
        var albumMarkers: [BulkDownloadAlbumMarker] = []
        var albumMarkerIds = Set<String>()
        var totalBytes: Int64 = 0

        func appendPlaylistMarker(_ marker: BulkDownloadPlaylistMarker?) {
            guard let marker, playlistMarkerIds.insert(marker.id).inserted else { return }
            playlistMarkers.append(marker)
        }

        func appendAlbumMarker(_ marker: BulkDownloadAlbumMarker?) {
            guard let marker, albumMarkerIds.insert(marker.id).inserted else { return }
            albumMarkers.append(marker)
        }

        for unit in units.sorted(by: { $0.priority < $1.priority }) {
            let missingSongs = unit.songs.filter {
                !alreadyDownloaded.contains($0.id) && !plannedIds.contains($0.id)
            }
            if missingSongs.isEmpty {
                appendPlaylistMarker(unit.playlistMarker)
                appendAlbumMarker(unit.albumMarker)
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
                appendAlbumMarker(unit.albumMarker)
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
            albumMarkers: albumMarkers,
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
            albumMarkers: plan.albumMarkers,
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
        if let p = currentProgress[key] { return .downloading(progress: p) }
        if pendingJobKeys.contains(key) {
            return .queued
        }
        if retryingJobs.contains(key) {
            return .queued
        }
        return .none
    }

    // MARK: - Job Lifecycle

    private func startNextJobs() {
        guard let session else { return }
        while inflightJobs.count < effectiveMaxConcurrent, let job = popNextPendingJob() {
            let jobKey = Self.key(songId: job.song.id, serverId: job.serverId)
            pendingJobKeys.remove(jobKey)
            let task = session.downloadTask(with: job.downloadURL)
            task.priority = URLSessionTask.highPriority
            if let desc = encodeJob(job) { task.taskDescription = desc }
            inflightJobs[task.taskIdentifier] = job
            jobKeyByTask[task.taskIdentifier] = jobKey
            let initialProgress: Double = job.requestedFormat != nil ? -1 : 0
            publishProgress(key: jobKey, value: initialProgress)
            stateSubject.send((jobKey, .downloading(progress: initialProgress)))
            task.resume()
        }
    }

    func handleProgress(_ samples: [DownloadProgressSample]) {
        var didChange = false
        for sample in samples {
            guard let key = jobKeyByTask[sample.taskIdentifier] else { continue }
            let progress = sample.total > 0
                ? Double(sample.written) / Double(sample.total)
                : -1
            guard currentProgress[key] != progress else { continue }
            currentProgress[key] = progress
            didChange = true
        }
        guard didChange else { return }

        // The URLSession delegate already limits these batches to one per UI
        // interval. Publish this batch directly instead of adding a second delay.
        progressPublishGeneration &+= 1
        progressPublishTask?.cancel()
        progressPublishTask = nil
        publishProgressSnapshotIfChanged()
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
        if currentProgress[key] != 1 {
            // Audio transfer is complete. Keep the ring at 100% while payload
            // validation, artwork and the database commit finish.
            currentProgress[key] = 1
            publishProgressImmediately()
        }
        defer {
            inCompletionJobs.removeValue(forKey: key)
            resetBatchIfDone()
        }

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

        startNextJobs()
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
            await DownloadStore.shared.removeRecord(songId: job.song.id, serverId: job.serverId)
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
            let retryToken = retryingJobs.register(next, forKey: key)
            publishProgress(key: key, value: nil)
            stateSubject.send((key, .queued))
            startNextJobs()
            let backoff = pow(2.0, Double(next.attempt))
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard let retryJob = retryingJobs.takeValue(forKey: key, token: retryToken) else {
                if cancelledKeys.remove(key) != nil {
                    publishProgress(key: key, value: nil)
                    stateSubject.send((key, .none))
                }
                startNextJobs()
                resetBatchIfDone()
                return
            }
            if cancelledKeys.contains(key) {
                cancelledKeys.remove(key)
                publishProgress(key: key, value: nil)
                stateSubject.send((key, .none))
                startNextJobs()
                return
            }
            appendPendingJob(retryJob)
            pendingJobKeys.insert(key)
            stateSubject.send((key, .queued))
            startNextJobs()
            return
        }
        // Letzter Versuch ohne Transcoding (Original) — wenn wir bisher mit Format gefragt haben.
        if job.requestedFormat != nil, !job.fellBackToRaw {
            let retryToken = retryingJobs.register(job, forKey: key)
            startNextJobs()
            let api = await currentAPI(for: job.serverId)
            guard let retryJob = retryingJobs.takeValue(forKey: key, token: retryToken) else {
                if cancelledKeys.remove(key) != nil {
                    publishProgress(key: key, value: nil)
                    stateSubject.send((key, .none))
                }
                startNextJobs()
                resetBatchIfDone()
                return
            }
            if cancelledKeys.contains(key) {
                cancelledKeys.remove(key)
                publishProgress(key: key, value: nil)
                stateSubject.send((key, .none))
                startNextJobs()
                return
            }
            if let api,
               let rawURL = api.api.downloadURL(
                   for: retryJob.song.id,
                   server: api.server,
                   password: api.password,
                   transcoding: nil
               ) {
                var raw = retryJob
                raw.attempt = 0
                raw.fellBackToRaw = true
                raw.downloadURL = rawURL
                raw.fileExtension = retryJob.song.suffix?.pathSafeFileExtension() ?? "mp3"
                publishProgress(key: key, value: nil)
                appendPendingJob(raw)
                pendingJobKeys.insert(key)
                stateSubject.send((key, .queued))
                startNextJobs()
                return
            }
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
        guard !hasTrackedJobs else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.flushBatchIfStillIdle()
        }
    }

    private func flushBatchIfStillIdle() {
        guard !hasTrackedJobs else { return }
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
            if let coverArtId = job.coverArtId,
               let sharedPath = await ensureSharedArtwork(
                   artId: coverArtId,
                   url: coverURL,
                   serverId: job.serverId
               ) {
                do {
                    try FileManager.default.linkItem(
                        at: URL(fileURLWithPath: sharedPath),
                        to: URL(fileURLWithPath: coverPath)
                    )
                } catch {
                    try? FileManager.default.copyItem(
                        at: URL(fileURLWithPath: sharedPath),
                        to: URL(fileURLWithPath: coverPath)
                    )
                }
            } else if let data = await artworkPipeline.data(
                for: "\(job.serverId)::song::\(job.song.id)",
                url: coverURL
            ) {
                try? data.write(to: URL(fileURLWithPath: coverPath), options: .atomic)
            }
        }
        if let artId = job.artistCoverArtId, let artURL = job.artistCoverURL {
            _ = await ensureSharedArtwork(
                artId: artId,
                url: artURL,
                serverId: job.serverId
            )
        }
        if let artId = job.albumCoverArtId, let artURL = job.albumCoverURL {
            _ = await ensureSharedArtwork(
                artId: artId,
                url: artURL,
                serverId: job.serverId
            )
        }
    }

    private func ensureSharedArtwork(
        artId: String,
        url: URL,
        serverId: String
    ) async -> String? {
        let artPath = Self.artistCoverPath(serverId: serverId, artId: artId)
        if !FileManager.default.fileExists(atPath: artPath) {
            let artDirectory = Self.artworkDirectory(serverId: serverId)
            try? FileManager.default.createDirectory(
                at: artDirectory,
                withIntermediateDirectories: true
            )
            guard let data = await artworkPipeline.data(
                for: "\(serverId)::\(artId)",
                url: url
            ) else { return nil }
            if !FileManager.default.fileExists(atPath: artPath) {
                try? data.write(to: URL(fileURLWithPath: artPath), options: .atomic)
            }
        }
        guard FileManager.default.fileExists(atPath: artPath) else { return nil }
        LocalArtworkIndex.shared.set(artId: artId, path: artPath)
        return artPath
    }

    private func publishProgress(key: String, value: Double?) {
        if let value {
            guard currentProgress[key] != value else { return }
            currentProgress[key] = value
            scheduleProgressPublish()
        } else {
            guard currentProgress.removeValue(forKey: key) != nil else { return }
            publishProgressImmediately()
        }
    }

    private func scheduleProgressPublish() {
        guard progressPublishTask == nil else { return }
        let delay = progressPublishIntervalNanoseconds
        progressPublishGeneration &+= 1
        let generation = progressPublishGeneration
        progressPublishTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.publishScheduledProgress(generation: generation)
        }
    }

    private func publishScheduledProgress(generation: UInt64) {
        guard generation == progressPublishGeneration else { return }
        progressPublishTask = nil
        publishProgressSnapshotIfChanged()
    }

    private func publishProgressImmediately() {
        progressPublishGeneration &+= 1
        progressPublishTask?.cancel()
        progressPublishTask = nil
        publishProgressSnapshotIfChanged()
    }

    private func publishProgressSnapshotIfChanged() {
        guard currentProgress != lastPublishedProgress else { return }
        lastPublishedProgress = currentProgress
        progressSubject.send(currentProgress)
    }

    private func clearProgress() {
        currentProgress.removeAll()
        publishProgressImmediately()
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

private nonisolated final class DownloadSessionCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    nonisolated(unsafe) weak var service: DownloadService?
    private let progressQueue: DispatchQueue
    private let progressCoalescer: DownloadProgressCoalescer

    override init() {
        let queue = DispatchQueue(
            label: "ch.vkugler.Shelv.download-progress",
            qos: .utility
        )
        progressQueue = queue
        progressCoalescer = DownloadProgressCoalescer(
            schedule: { [queue] work in
                queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
            },
            emit: { _ in }
        )
        super.init()
        progressCoalescer.setEmit { [weak self] samples in
            guard let service = self?.service else { return }
            Task.detached(priority: .utility) {
                await service.handleProgress(samples)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progressCoalescer.record(DownloadProgressSample(
            taskIdentifier: downloadTask.taskIdentifier,
            written: totalBytesWritten,
            total: totalBytesExpectedToWrite
        ))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        progressCoalescer.discard(taskIdentifier: id)
        let safeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelv-dl-\(id)-\(UUID().uuidString)")
        do {
            // The URLSession file already lives on the same local volume in the
            // common case. Renaming avoids copying the whole song while the user scrolls.
            try FileManager.default.moveItem(at: location, to: safeURL)
        } catch {
            do {
                try FileManager.default.copyItem(at: location, to: safeURL)
            } catch let stagingError {
                let desc = downloadTask.taskDescription
                Task { [weak service] in
                    await service?.handleError(
                        taskIdentifier: id,
                        error: stagingError,
                        taskDescription: desc
                    )
                }
                return
            }
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
        progressCoalescer.discard(taskIdentifier: id)
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
