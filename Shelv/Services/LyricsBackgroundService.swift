import Foundation
@preconcurrency import Combine

/// Bulk-Lyrics-Downloader via Background-URLSession. iOS lädt die Requests im
/// `nsurlsessiond`-Daemon — läuft weiter bei gesperrtem Handy und sogar nach App-Kill.
actor LyricsBackgroundService {
    static let shared = LyricsBackgroundService()

    private let coordinator = LyricsSessionCoordinator()
    private var session: URLSession?
    private let backgroundIdentifier = "ch.vkugler.Shelv.lyrics.bg"
    /// Number of song pipelines running at once. Each pipeline walks
    /// Navidrome -> LRCLIB custom/online cached -> LRCLIB custom/online full before another song takes that slot.
    private let maxConcurrent = 5

    // MARK: - Job

    private struct LyricsJob: Codable {
        let songId: String
        let serverId: String
        let songTitle: String
        let artistName: String?
        let albumName: String?
        let albumId: String?
        let coverArt: String?
        let duration: Int?
        let navidromeURL: URL?    // nil wenn Toggle aus
        let lrcCachedURL: URL?    // /api/get?cached=true
        let lrcGetURL: URL?       // /api/get (volle Suche)
        let lrcOnlineCachedURL: URL?
        let lrcOnlineGetURL: URL?
        var layer: Layer
        var retryCount: Int

        enum Layer: String, Codable {
            case navidrome, lrcCached, lrcGet, lrcOnlineCached, lrcOnlineGet
        }
    }

    private static let maxRetries = 2  // pro Layer bei Netzwerkfehlern

    // MARK: - State

    private var pending: [LyricsJob] = []
    private var inflight: [Int: LyricsJob] = [:]
    /// O(1)-Lookup für „dieser Song ist gerade in der Queue oder läuft schon".
    /// Key = "serverId::songId".
    private var trackedKeys: Set<String> = []
    /// Jobs, die der User abgebrochen hat. Verhindert, dass späte Background-Completions
    /// oder verzögerte Retries nach `cancelAll()` wieder Arbeit anstoßen.
    private var cancelledKeys: Set<String> = []
    /// Snapshot der bereits in der DB gecachten Song-IDs. Wird einmal pro Bulk-Session
    /// geladen statt pro enqueueSongs-Call (das wäre 1 DB-Query pro Album beim Streaming).
    private var cachedSongIdsSnapshot: Set<String>?

    private var totalCount: Int = 0
    private var completedCount: Int = 0

    nonisolated(unsafe) private let progressSubject = CurrentValueSubject<(completed: Int, total: Int)?, Never>(nil)
    nonisolated var progressUpdates: AnyPublisher<(completed: Int, total: Int)?, Never> {
        progressSubject.eraseToAnyPublisher()
    }

    private init() {
        coordinator.service = self
    }

    // MARK: - Setup

    func setup() {
        if session == nil {
            let cfg = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            cfg.isDiscretionary = false
            cfg.sessionSendsLaunchEvents = true
            cfg.allowsCellularAccess = true
            cfg.httpMaximumConnectionsPerHost = maxConcurrent
            cfg.timeoutIntervalForRequest = 12
            cfg.timeoutIntervalForResource = 30
            // TCP-Connection-Reuse über mehrere Requests hinweg (HTTP/2-Multiplexing nutzbar)
            cfg.shouldUseExtendedBackgroundIdleMode = true
            // Lyrics-Bulk soll pro Song sichtbar weiterlaufen. Wenn ein Custom-Server
            // nicht erreichbar ist, darf nsurlsessiond nicht minutenlang auf Connectivity warten.
            cfg.waitsForConnectivity = false
            let s = URLSession(configuration: cfg, delegate: coordinator, delegateQueue: nil)
            session = s
            s.getAllTasks { [weak self] tasks in
                Task { await self?.restoreInflightTasks(tasks) }
            }
        }
    }

    private func restoreInflightTasks(_ tasks: [URLSessionTask]) {
        for task in tasks {
            guard let dlTask = task as? URLSessionDownloadTask else { continue }
            // Tasks aus alten App-Versionen mit anderem Job-Format → wegcancellen
            // statt Slots zu verschwenden
            guard let desc = dlTask.taskDescription,
                  let job = decodeJob(desc) else {
                task.cancel()
                continue
            }
            let key = key(for: job)
            guard !cancelledKeys.contains(key) else {
                task.cancel()
                continue
            }
            inflight[dlTask.taskIdentifier] = job
            trackedKeys.insert(key)
            totalCount += 1
        }
        publishProgress()
    }

    // MARK: - Enqueueing

    func isRunning() -> Bool {
        !pending.isEmpty || !inflight.isEmpty
    }

    func progressSnapshot() -> (completed: Int, total: Int)? {
        totalCount > 0 ? (completedCount, totalCount) : nil
    }

    private func key(for job: LyricsJob) -> String {
        "\(job.serverId)::\(job.songId)"
    }

    @discardableResult
    private func registerForProcessing(_ job: LyricsJob) -> Bool {
        let key = key(for: job)
        guard !cancelledKeys.contains(key) else { return false }
        if trackedKeys.insert(key).inserted {
            totalCount += 1
        }
        return true
    }

    private func isActive(_ job: LyricsJob) -> Bool {
        let key = key(for: job)
        return trackedKeys.contains(key) && !cancelledKeys.contains(key)
    }

    func enqueueSongs(_ songs: [Song], serverId: String) async {
        guard let api = await currentAPI(for: serverId) else { return }

        // Toggle vom Main-Actor lesen
        let includeNavidrome: Bool = await MainActor.run {
            UserDefaults.standard.bool(forKey: "includeNavidromeLyrics")
        }
        let customLrcLibEnabled = LrcLibEndpoint.isCustomEnabled
        let onlineFallbackEnabled = LrcLibEndpoint.isOnlineFallbackEnabled

        if cachedSongIdsSnapshot == nil {
            cachedSongIdsSnapshot = await LyricsService.shared.cachedSongIds(serverId: serverId)
        }
        let cached = cachedSongIdsSnapshot ?? []
        var enqueuedCount = 0

        for song in songs {
            let key = "\(serverId)::\(song.id)"
            if trackedKeys.contains(key) { continue }
            if cached.contains(song.id) { continue }
            cancelledKeys.remove(key)

            let navURL: URL? = includeNavidrome
                ? api.api.lyricsURL(for: song.id, server: api.server, password: api.password)
                : nil
            let lrcCachedRequest = Self.buildLrcLibRequest(cached: true,
                                                           title: song.title, artist: song.artist,
                                                           album: song.album, duration: song.duration)
            let lrcGetRequest = Self.buildLrcLibRequest(cached: false,
                                                        title: song.title, artist: song.artist,
                                                        album: song.album, duration: song.duration)
            let needsOnlineFallback = onlineFallbackEnabled
                && ((lrcCachedRequest?.isCustom == true) || (lrcGetRequest?.isCustom == true))
            let lrcOnlineCachedURL = needsOnlineFallback
                ? Self.buildLrcLibRequest(cached: true,
                                          title: song.title, artist: song.artist,
                                          album: song.album, duration: song.duration,
                                          forceOnline: true)?.url
                : nil
            let lrcOnlineGetURL = needsOnlineFallback
                ? Self.buildLrcLibRequest(cached: false,
                                          title: song.title, artist: song.artist,
                                          album: song.album, duration: song.duration,
                                          forceOnline: true)?.url
                : nil

            // Initial-Layer: Navidrome falls Toggle an UND URL gebaut, sonst lrcCached
            let initialLayer: LyricsJob.Layer = (includeNavidrome && navURL != nil) ? .navidrome : .lrcCached

            let job = LyricsJob(
                songId: song.id,
                serverId: serverId,
                songTitle: song.title,
                artistName: song.artist,
                albumName: song.album,
                albumId: song.albumId,
                coverArt: song.coverArt,
                duration: song.duration,
                navidromeURL: navURL,
                lrcCachedURL: lrcCachedRequest?.url,
                lrcGetURL: lrcGetRequest?.url,
                lrcOnlineCachedURL: lrcOnlineCachedURL,
                lrcOnlineGetURL: lrcOnlineGetURL,
                layer: initialLayer,
                retryCount: 0
            )
            pending.append(job)
            trackedKeys.insert(key)
            totalCount += 1
            enqueuedCount += 1
        }

        let navidromeStatus = includeNavidrome ? "on" : "off"
        let customStatus = customLrcLibEnabled ? "on" : "off"
        let fallbackStatus = customLrcLibEnabled ? (onlineFallbackEnabled ? "on" : "off") : "n/a"
        DBErrorLog.logLyrics(
            "Bulk plan → queue \(enqueuedCount)/\(songs.count), Navidrome \(navidromeStatus), LRCLIB custom \(customStatus), LRCLIB.net fallback \(fallbackStatus)"
        )
        publishProgress()
        startNextJobs()
    }

    // MARK: - Cancel

    func cancelAll() {
        for key in trackedKeys {
            cancelledKeys.insert(key)
        }
        pending.removeAll()
        let inflightTaskIds = Array(inflight.keys)
        inflight.removeAll()
        trackedKeys.removeAll()
        cachedSongIdsSnapshot = nil
        session?.getAllTasks { tasks in
            for task in tasks where inflightTaskIds.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
        totalCount = 0
        completedCount = 0
        progressSubject.send(nil)
    }

    // MARK: - Job lifecycle

    private func startNextJobs() {
        guard let session else { return }
        while inflight.count < maxConcurrent, !pending.isEmpty {
            let job = pending.removeFirst()
            let url: URL?
            switch job.layer {
            case .navidrome: url = job.navidromeURL
            case .lrcCached: url = job.lrcCachedURL
            case .lrcGet:    url = job.lrcGetURL
            case .lrcOnlineCached: url = job.lrcOnlineCachedURL
            case .lrcOnlineGet:    url = job.lrcOnlineGetURL
            }
            guard let url else {
                DBErrorLog.logLyrics("Bulk skipped → \(layerDescription(job.layer)): missing URL for \(job.songTitle)")
                advanceLayerOrFinish(job: job)
                continue
            }
            logRequest(job: job, url: url)
            var request = URLRequest(url: url, timeoutInterval: 12)
            if job.layer != .navidrome {
                request.setValue("Shelv/1.0 (https://github.com/gatzenga/Shelv)", forHTTPHeaderField: "User-Agent")
            }
            let task = session.downloadTask(with: request)
            if let desc = encodeJob(job) { task.taskDescription = desc }
            inflight[task.taskIdentifier] = job
            task.resume()
        }
    }

    func handleCompletion(taskIdentifier: Int, data: Data, statusCode: Int, taskDescription: String?) async {
        let job: LyricsJob
        if let existing = inflight.removeValue(forKey: taskIdentifier) {
            job = existing
        } else if let desc = taskDescription, let decoded = decodeJob(desc) {
            job = decoded
        } else {
            return
        }
        guard registerForProcessing(job) else { return }

        // Netzwerk-Fehler (5xx, 429) → Retry-Pfad
        if (500...599).contains(statusCode) || statusCode == 429 {
            DBErrorLog.logLyrics("Bulk response → \(layerDescription(job.layer)) HTTP \(statusCode): \(job.songTitle)")
            handleNetworkFailure(job: job)
            return
        }

        // Erfolgreiche Antwort parsen
        var savedRecord: LyricsRecord?
        if statusCode == 200 {
            switch job.layer {
            case .navidrome: savedRecord = parseNavidrome(data: data, job: job)
            case .lrcCached, .lrcGet, .lrcOnlineCached, .lrcOnlineGet:
                savedRecord = parseLrcLib(data: data, job: job)
            }
        }

        if let record = savedRecord {
            Task { await LyricsService.shared.save(record) }
            finishJob(job, result: record.source)
            return
        }

        // Kein Match → weiter zur nächsten Layer (oder fertig)
        logNoMatch(job: job, statusCode: statusCode)
        advanceLayerOrFinish(job: job)
    }

    /// Layer-Übergang: navidrome → lrcCached → lrcGet → lrcOnlineCached → lrcOnlineGet → saveNone.
    /// retryCount für die neue Layer wird zurückgesetzt.
    private func advanceLayerOrFinish(job: LyricsJob) {
        guard isActive(job) else { return }
        switch job.layer {
        case .navidrome:
            var next = job
            next.layer = .lrcCached
            next.retryCount = 0
            DBErrorLog.logLyrics("Bulk next → \(layerDescription(.lrcCached)): \(job.songTitle)")
            pending.insert(next, at: 0)
            startNextJobs()
        case .lrcCached:
            var next = job
            next.layer = .lrcGet
            next.retryCount = 0
            DBErrorLog.logLyrics("Bulk next → \(layerDescription(.lrcGet)): \(job.songTitle)")
            pending.insert(next, at: 0)
            startNextJobs()
        case .lrcGet:
            guard job.lrcOnlineCachedURL != nil else {
                if LrcLibEndpoint.isCustomEnabled && !LrcLibEndpoint.isOnlineFallbackEnabled {
                    DBErrorLog.logLyrics("Bulk fallback off → LRCLIB online skipped: \(job.songTitle)")
                }
                saveNone(job: job)
                return
            }
            var next = job
            next.layer = .lrcOnlineCached
            next.retryCount = 0
            DBErrorLog.logLyrics("Bulk fallback → LRCLIB online cached: \(job.songTitle)")
            pending.insert(next, at: 0)
            startNextJobs()
        case .lrcOnlineCached:
            var next = job
            next.layer = .lrcOnlineGet
            next.retryCount = 0
            DBErrorLog.logLyrics("Bulk next → LRCLIB online full: \(job.songTitle)")
            pending.insert(next, at: 0)
            startNextJobs()
        case .lrcOnlineGet:
            saveNone(job: job)
        }
    }

    func handleError(taskIdentifier: Int, error: Error?, taskDescription: String?) async {
        let job: LyricsJob
        if let existing = inflight.removeValue(forKey: taskIdentifier) {
            job = existing
        } else if let desc = taskDescription, let decoded = decodeJob(desc) {
            job = decoded
        } else { return }
        guard registerForProcessing(job) else { return }

        // User-Cancel: kein Save, kein Progress-Bump
        if let urlError = error as? URLError, urlError.code == .cancelled { return }

        DBErrorLog.logLyrics("Bulk error → \(layerDescription(job.layer)): \(job.songTitle) — \(error?.localizedDescription ?? "unknown error")")
        handleNetworkFailure(job: job)
    }

    /// Bis zu `maxRetries` mit Backoff in der aktuellen Layer, danach zur nächsten Layer.
    private func handleNetworkFailure(job: LyricsJob) {
        guard isActive(job) else { return }
        if job.retryCount < Self.maxRetries {
            var next = job
            next.retryCount += 1
            let attempt = next.retryCount  // 1 oder 2
            let backoffMs: UInt64 = attempt == 1 ? 500 : 1500
            let jitter = UInt64.random(in: 0...250)
            DBErrorLog.logLyrics("Bulk retry → \(layerDescription(job.layer)) attempt \(attempt + 1): \(job.songTitle)")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: (backoffMs + jitter) * 1_000_000)
                await self?.requeue(next)
            }
            // Freigewordenen Slot direkt mit dem nächsten Pending-Job füllen
            startNextJobs()
        } else {
            DBErrorLog.logLyrics("Bulk give up → \(layerDescription(job.layer)): \(job.songTitle)")
            advanceLayerOrFinish(job: job)
        }
    }

    private func requeue(_ job: LyricsJob) {
        guard isActive(job) else { return }
        pending.insert(job, at: 0)
        startNextJobs()
    }

    private func saveNone(job: LyricsJob) {
        guard isActive(job) else { return }
        DBErrorLog.logLyrics("Bulk no lyrics → \(job.songTitle)")
        let none = LyricsRecord(
            songId: job.songId, serverId: job.serverId, source: "none",
            plainText: nil, syncedLrc: nil, isSynced: false,
            isInstrumental: false, language: nil,
            fetchedAt: Date().timeIntervalSince1970,
            songTitle: job.songTitle, artistName: job.artistName,
            albumId: job.albumId, coverArt: job.coverArt,
            songDuration: job.duration
        )
        Task { await LyricsService.shared.save(none) }
        finishJob(job, result: "none")
    }

    private func finishJob(_ job: LyricsJob, result: String) {
        guard isActive(job) else { return }
        trackedKeys.remove(key(for: job))
        completedCount += 1
        DBErrorLog.logLyrics("Bulk complete → \(result): \(job.songTitle) (\(completedCount)/\(totalCount))")
        publishProgress()
        startNextJobs()
    }

    private func logRequest(job: LyricsJob, url _: URL) {
        DBErrorLog.logLyrics("Bulk request → \(layerDescription(job.layer)): \(job.songTitle)")
    }

    private func logNoMatch(job: LyricsJob, statusCode: Int) {
        let status = statusCode > 0 ? "HTTP \(statusCode)" : "no HTTP response"
        DBErrorLog.logLyrics("Bulk no match → \(layerDescription(job.layer)) \(status): \(job.songTitle)")
    }

    private func layerDescription(_ layer: LyricsJob.Layer) -> String {
        switch layer {
        case .navidrome:
            return "Navidrome"
        case .lrcCached:
            return LrcLibEndpoint.isCustomEnabled ? "LRCLIB custom cached" : "LRCLIB online cached"
        case .lrcGet:
            return LrcLibEndpoint.isCustomEnabled ? "LRCLIB custom full" : "LRCLIB online full"
        case .lrcOnlineCached:
            return "LRCLIB online cached"
        case .lrcOnlineGet:
            return "LRCLIB online full"
        }
    }

    // MARK: - Parsing

    private func parseNavidrome(data: Data, job: LyricsJob) -> LyricsRecord? {
        guard let entry = SubsonicAPIService.shared.parseLyricsResponse(data: data),
              let lines = entry.line, !lines.isEmpty else { return nil }

        let plain = lines.map { $0.value }.joined(separator: "\n")
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var lrc: String? = nil
        if entry.synced {
            let lrcLines = lines.compactMap { line -> String? in
                guard let ms = line.start else { return nil }
                let min = (ms / 1000) / 60
                let sec = (ms / 1000) % 60
                let cs  = (ms % 1000) / 10
                return String(format: "[%02d:%02d.%02d] %@", min, sec, cs, line.value)
            }
            lrc = lrcLines.isEmpty ? nil : lrcLines.joined(separator: "\n")
        }

        return LyricsRecord(
            songId: job.songId, serverId: job.serverId, source: "navidrome",
            plainText: plain, syncedLrc: lrc,
            isSynced: entry.synced && lrc != nil,
            isInstrumental: false, language: entry.lang,
            fetchedAt: Date().timeIntervalSince1970,
            songTitle: job.songTitle, artistName: job.artistName,
            albumId: job.albumId, coverArt: job.coverArt,
            songDuration: job.duration
        )
    }

    private struct LrcLibResponse: Decodable {
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private func parseLrcLib(data: Data, job: LyricsJob) -> LyricsRecord? {
        guard let lrc = try? JSONDecoder().decode(LrcLibResponse.self, from: data) else { return nil }

        if lrc.instrumental == true {
            return LyricsRecord(
                songId: job.songId, serverId: job.serverId, source: "lrclib",
                plainText: nil, syncedLrc: nil, isSynced: false,
                isInstrumental: true, language: nil,
                fetchedAt: Date().timeIntervalSince1970,
                songTitle: job.songTitle, artistName: job.artistName,
                albumId: job.albumId, coverArt: job.coverArt,
                songDuration: job.duration
            )
        }
        guard lrc.plainLyrics != nil || lrc.syncedLyrics != nil else { return nil }
        return LyricsRecord(
            songId: job.songId, serverId: job.serverId, source: "lrclib",
            plainText: lrc.plainLyrics, syncedLrc: lrc.syncedLyrics,
            isSynced: lrc.syncedLyrics != nil,
            isInstrumental: false, language: nil,
            fetchedAt: Date().timeIntervalSince1970,
            songTitle: job.songTitle, artistName: job.artistName,
            albumId: job.albumId, coverArt: job.coverArt,
            songDuration: job.duration
        )
    }

    /// cached=true → schnelle Cache-Schicht (~3.6s typ.), cached=false → volle Suche (~7.5s typ.)
    private static func buildLrcLibRequest(cached: Bool,
                                           title: String,
                                           artist: String?,
                                           album: String?,
                                           duration: Int?,
                                           forceOnline: Bool = false) -> LrcLibEndpoint.RequestInfo? {
        var items = [URLQueryItem(name: "track_name", value: title)]
        if let a = artist { items.append(URLQueryItem(name: "artist_name", value: a)) }
        if let a = album  { items.append(URLQueryItem(name: "album_name",  value: a)) }
        if let d = duration { items.append(URLQueryItem(name: "duration", value: "\(d)")) }
        if cached { items.append(URLQueryItem(name: "cached", value: "true")) }
        return LrcLibEndpoint.apiRequest(queryItems: items, forceOnline: forceOnline)
    }

    // MARK: - Codable Helpers

    private func encodeJob(_ job: LyricsJob) -> String? {
        guard let data = try? JSONEncoder().encode(job) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJob(_ string: String) -> LyricsJob? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LyricsJob.self, from: data)
    }

    // MARK: - Progress

    private func publishProgress() {
        if totalCount > 0 {
            progressSubject.send((completedCount, totalCount))
        } else {
            progressSubject.send(nil)
        }
        if pending.isEmpty && inflight.isEmpty {
            // Auto-Reset wenn fertig
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self?.resetIfStillIdle()
            }
        }
    }

    private func resetIfStillIdle() {
        guard pending.isEmpty, inflight.isEmpty else { return }
        totalCount = 0
        completedCount = 0
        cachedSongIdsSnapshot = nil
        progressSubject.send(nil)
    }

    // MARK: - Credentials

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
        // Kein stableId-Check: Lyrics werden historisch mit serverId == UUID.uuidString
        // gespeichert, nicht mit stableId. Wir vertrauen einfach dem aktuell aktiven Server.
        guard let server = snapshot.0, let pw = snapshot.1 else { return nil }
        return ResolvedAPI(api: api, server: server, password: pw)
    }
}

// MARK: - Coordinator

private final class LyricsSessionCoordinator: NSObject, URLSessionDownloadDelegate {
    nonisolated(unsafe) weak var service: LyricsBackgroundService?

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // Lyrics-Responses sind klein (wenige KB) → direkt inline lesen, kein Temp-File
        let data = (try? Data(contentsOf: location)) ?? Data()
        let desc = downloadTask.taskDescription
        Task { [weak service] in
            await service?.handleCompletion(taskIdentifier: id, data: data, statusCode: status, taskDescription: desc)
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
        let identifier = session.configuration.identifier ?? ""
        DispatchQueue.main.async {
            BackgroundDownloadHandler.shared.consume(for: identifier)?()
        }
    }
}
