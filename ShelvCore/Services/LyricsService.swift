import Foundation
import GRDB

// MARK: - Database Record

struct LyricsRecord: Codable, FetchableRecord, PersistableRecord {
    var songId: String
    var serverId: String
    var source: String        // "navidrome" | "lrclib" | "none"
    var plainText: String?
    var syncedLrc: String?
    var isSynced: Bool
    var isInstrumental: Bool
    var language: String?
    var fetchedAt: Double     // Date.timeIntervalSince1970
    var songTitle: String?   = nil
    var artistName: String?  = nil
    var coverArt: String?    = nil
    var songDuration: Int?   = nil

    static let databaseTableName = "lyrics"
}

// MARK: - Lyrics Search Result

struct LyricsSearchResult: Identifiable {
    var id: String { songId }
    let songId: String
    let songTitle: String?   // nil wenn noch nicht in DB gespeichert
    let artistName: String?
    let coverArt: String?
    let snippet: String
    let duration: Int?
}

// MARK: - LRCLIB Response

enum LrcLibEndpoint {
    struct RequestInfo {
        let url: URL
        let source: String
        let fallbackReason: String?
        let isCustom: Bool
    }

    nonisolated static let defaultBaseURL = "https://lrclib.net"
    nonisolated static let useCustomKey = "useCustomLrcLibServer"
    nonisolated static let customBaseURLKey = "customLrcLibBaseURL"
    nonisolated static let onlineFallbackEnabledKey = "lrcLibOnlineFallbackEnabled"

    nonisolated static func apiURL(queryItems: [URLQueryItem]) -> URL? {
        apiRequest(queryItems: queryItems)?.url
    }

    nonisolated static func apiURL(queryItems: [URLQueryItem], forceOnline: Bool) -> URL? {
        apiRequest(queryItems: queryItems, forceOnline: forceOnline)?.url
    }

    nonisolated static func apiRequest(queryItems: [URLQueryItem], forceOnline: Bool = false) -> RequestInfo? {
        guard let resolved = selectedBaseURL(forceOnline: forceOnline) else { return nil }
        let base = resolved.url
        let source = resolved.isCustom ? "LRCLIB custom" : "LRCLIB online"
        var endpoint = base
        let path = endpoint.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        if path.hasSuffix("api/get") {
            // User supplied a full endpoint; keep it usable.
        } else if path.hasSuffix("api") {
            endpoint.appendPathComponent("get")
        } else {
            endpoint.appendPathComponent("api")
            endpoint.appendPathComponent("get")
        }

        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.queryItems = queryItems
        guard let url = comps.url else { return nil }
        return RequestInfo(url: url, source: source, fallbackReason: resolved.fallbackReason, isCustom: resolved.isCustom)
    }

    nonisolated static func sourceDescription(for url: URL) -> String {
        guard let defaultHost = URL(string: defaultBaseURL)?.host?.lowercased(),
              url.host?.lowercased() == defaultHost
        else { return "LRCLIB custom" }
        return "LRCLIB online"
    }

    nonisolated static var isCustomEnabled: Bool {
        UserDefaults.standard.bool(forKey: useCustomKey)
    }

    nonisolated static var isOnlineFallbackEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: onlineFallbackEnabledKey) != nil else { return true }
        return defaults.bool(forKey: onlineFallbackEnabledKey)
    }

    nonisolated private static func selectedBaseURL(forceOnline: Bool = false) -> (url: URL, isCustom: Bool, fallbackReason: String?)? {
        if forceOnline {
            return (URL(string: defaultBaseURL)!, false, nil)
        }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: useCustomKey) {
            if let custom = normalizedBaseURL(from: defaults.string(forKey: customBaseURLKey) ?? "") {
                return (custom, true, nil)
            }
            guard isOnlineFallbackEnabled else { return nil }
            return (URL(string: defaultBaseURL)!, false, "custom server URL is invalid or empty")
        }
        return (URL(string: defaultBaseURL)!, false, nil)
    }

    nonisolated private static func normalizedBaseURL(from rawValue: String) -> URL? {
        var raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let hasScheme = raw.range(
            of: #"^[A-Za-z][A-Za-z0-9+\-.]*://"#,
            options: .regularExpression
        ) != nil
        if !hasScheme {
            raw = "https://\(raw)"
        }

        guard var comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              comps.host?.isEmpty == false
        else { return nil }

        comps.scheme = scheme
        comps.query = nil
        comps.fragment = nil
        while comps.path.hasSuffix("/") {
            comps.path.removeLast()
        }
        return comps.url
    }
}

nonisolated private struct LrcLibResponse: Decodable, Sendable {
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

// MARK: - LyricsService

actor LyricsService {
    static let shared = LyricsService()

    private static let lrcLibSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private var pool: DatabasePool?
    private init() {}

    // MARK: - Setup

    func setup() {
        guard pool == nil else { return }
        let url = Self.dbURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var config = Configuration()
            config.label = "shelv.db.lyrics"
            config.qos = .userInitiated
            let p = try DatabasePool(path: url.path, configuration: config)
            Self.applyDataProtection(at: url)
            var m = DatabaseMigrator()
            m.registerMigration("v1_createLyrics") { db in
                try db.create(table: "lyrics", ifNotExists: true) { t in
                    t.column("songId",         .text).notNull()
                    t.column("serverId",       .text).notNull()
                    t.column("source",         .text).notNull().defaults(to: "none")
                    t.column("plainText",      .text)
                    t.column("syncedLrc",      .text)
                    t.column("isSynced",       .boolean).notNull().defaults(to: false)
                    t.column("isInstrumental", .boolean).notNull().defaults(to: false)
                    t.column("language",       .text)
                    t.column("fetchedAt",      .double).notNull()
                    t.primaryKey(["songId", "serverId"])
                }
            }
            // Die iOS- und macOS-App hatten vor der Zusammenführung getrennte
            // Migrations-Historien (macOS: Metadata-Spalten schon in v1 + eigene
            // "v2_addDuration"). Alle Spalten-Migrationen prüfen deshalb defensiv,
            // ob die Spalte bereits existiert — sonst bricht der Start auf
            // Bestands-Datenbanken der jeweils anderen Linie mit "duplicate column".
            m.registerMigration("v2_addSongMetadata") { db in
                let cols = try db.columns(in: "lyrics").map(\.name)
                let missing = ["songTitle", "artistName", "coverArt"].filter { !cols.contains($0) }
                guard !missing.isEmpty else { return }
                try db.alter(table: "lyrics") { t in
                    for col in missing { t.add(column: col, .text) }
                }
            }
            // Legacy-ID der alten Desktop-App — registriert, damit GRDB deren
            // Bestands-DBs (applied: v1, v2_addDuration) sauber weiterführt.
            m.registerMigration("v2_addDuration") { db in
                let cols = try db.columns(in: "lyrics").map(\.name)
                guard !cols.contains("songDuration") else { return }
                try db.alter(table: "lyrics") { t in
                    t.add(column: "songDuration", .integer)
                }
            }
            m.registerMigration("v3_addDuration") { db in
                let cols = try db.columns(in: "lyrics").map(\.name)
                guard !cols.contains("songDuration") else { return }
                try db.alter(table: "lyrics") { t in
                    t.add(column: "songDuration", .integer)
                }
            }
            try m.migrate(p)
            pool = p
        } catch {
            print("[LyricsService] DB setup failed: \(error)")
        }
    }

    static var dbURL: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_lyrics/lyrics.db")
    }

    private static func applyDataProtection(at url: URL) {
        #if os(iOS)
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
        }
        #endif
    }

    nonisolated static func diskSizeBytes() -> Int {
        // SQLite im WAL-Modus: Haupt-DB + -wal + -shm zusammen zählen.
        let base = dbURL
        let suffixes = ["", "-wal", "-shm"]
        return suffixes.reduce(0) { total, suffix in
            let url = base.deletingLastPathComponent()
                .appendingPathComponent(base.lastPathComponent + suffix)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + size
        }
    }

    // MARK: - Read / Write

    func lyrics(songId: String, serverId: String) -> LyricsRecord? {
        guard let pool else { return nil }
        return try? pool.read { db in
            try LyricsRecord
                .filter(Column("songId") == songId && Column("serverId") == serverId)
                .fetchOne(db)
        }
    }

    private func safeWrite(_ label: String = #function, _ block: (Database) throws -> Void) {
        guard let pool else {
            DBErrorLog.logLyrics("\(label): pool not initialized")
            return
        }
        do {
            try pool.write(block)
        } catch {
            DBErrorLog.logLyrics("\(label): \(error.localizedDescription)")
        }
    }

    func save(_ record: LyricsRecord) {
        safeWrite { db in try record.insert(db, onConflict: .replace) }
    }

    // MARK: - Stats

    func fetchedCount(serverId: String) -> Int {
        guard let pool else { return 0 }
        return (try? pool.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM lyrics WHERE serverId = ? AND source != 'none'",
                arguments: [serverId])
        }) ?? 0
    }

    /// Liefert in einem Query alle Song-IDs für die schon Lyrics existieren (source != 'none').
    /// Für Bulk-Enqueue: einmaliger DB-Hit statt N einzelne `lyrics(songId:serverId:)`-Calls.
    func cachedSongIds(serverId: String) -> Set<String> {
        guard let pool else { return [] }
        let rows: [String] = (try? pool.read { db in
            try String.fetchAll(db,
                sql: "SELECT songId FROM lyrics WHERE serverId = ? AND source != 'none'",
                arguments: [serverId])
        }) ?? []
        return Set(rows)
    }

    func totalRowCount() -> Int {
        guard let pool else { return 0 }
        return (try? pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lyrics")
        }) ?? 0
    }

    // MARK: - Metadata Backfill

    func updateMetadata(songId: String, serverId: String, title: String, artist: String?, coverArt: String?, duration: Int? = nil) {
        safeWrite { db in
            try db.execute(
                sql: """
                    UPDATE lyrics SET songTitle = ?, artistName = ?, coverArt = ?, songDuration = COALESCE(?, songDuration)
                    WHERE songId = ? AND serverId = ?
                """,
                arguments: [title, artist, coverArt, duration, songId, serverId]
            )
        }
    }

    // MARK: - Reset

    func reset(serverId: String) {
        safeWrite { db in
            try db.execute(sql: "DELETE FROM lyrics WHERE serverId = ?", arguments: [serverId])
        }
        shrinkDatabaseAfterReset()
    }

    func resetAll() {
        safeWrite { db in
            try db.execute(sql: "DELETE FROM lyrics")
        }
        shrinkDatabaseAfterReset()
    }

    private func shrinkDatabaseAfterReset() {
        guard let pool else { return }
        // VACUUM + WAL-Checkpoint(TRUNCATE): schrumpft sowohl .db als auch .db-wal.
        // Beides muss außerhalb einer Transaktion laufen.
        do {
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try db.execute(sql: "VACUUM")
            }
        } catch {
            DBErrorLog.logLyrics("reset VACUUM: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch & Cache

    private enum LrcLibOutcome {
        case found(LyricsRecord)
        case notFound
        case indeterminate
    }

    func fetchAndSave(song: Song, serverId: String) async -> LyricsRecord {
        let sixMonths: Double = 60 * 60 * 24 * 180
        if var cached = lyrics(songId: song.id, serverId: serverId),
           cached.source != "none",
           Date().timeIntervalSince1970 - cached.fetchedAt < sixMonths {
            if cached.songTitle == nil || cached.artistName == nil || cached.coverArt == nil || cached.songDuration == nil {
                cached.songTitle = cached.songTitle ?? song.title
                cached.artistName = cached.artistName ?? song.artist
                cached.coverArt = cached.coverArt ?? song.coverArt
                cached.songDuration = cached.songDuration ?? song.duration
                save(cached)
            }
            return cached
        }

        let includeNavidrome = UserDefaults.standard.bool(forKey: "includeNavidromeLyrics")
        if includeNavidrome, let lrc = await fetchFromNavidrome(song: song, serverId: serverId) {
            save(lrc); return lrc
        }

        switch await fetchFromLrcLib(song: song, serverId: serverId) {
        case .found(let lrc):
            save(lrc)
            return lrc
        case .notFound:
            let none = LyricsRecord(
                songId: song.id, serverId: serverId, source: "none",
                plainText: nil, syncedLrc: nil, isSynced: false,
                isInstrumental: false, language: nil,
                fetchedAt: Date().timeIntervalSince1970,
                songTitle: song.title, artistName: song.artist, coverArt: song.coverArt,
                songDuration: song.duration
            )
            save(none)
            return none
        case .indeterminate:
            return LyricsRecord(
                songId: song.id, serverId: serverId, source: "none",
                plainText: nil, syncedLrc: nil, isSynced: false,
                isInstrumental: false, language: nil,
                fetchedAt: Date().timeIntervalSince1970,
                songTitle: song.title, artistName: song.artist, coverArt: song.coverArt,
                songDuration: song.duration
            )
        }
    }

    // MARK: - Search

    func searchLyrics(text: String, serverId: String, limit: Int = 40) -> [LyricsSearchResult] {
        guard let pool, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let pattern = "%\(text)%"
        return (try? pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT songId, songTitle, artistName, coverArt, plainText, songDuration
                FROM lyrics
                WHERE serverId = ?
                  AND source != 'none'
                  AND isInstrumental = 0
                  AND plainText LIKE ? COLLATE NOCASE
                ORDER BY COALESCE(songTitle, songId)
                LIMIT ?
                """, arguments: [serverId, pattern, limit])
            .compactMap { row -> LyricsSearchResult? in
                guard let songId: String = row["songId"] else { return nil }
                let songTitle: String? = row["songTitle"]
                let plainText: String? = row["plainText"]
                let snippet = plainText.flatMap { extractSnippet(from: $0, query: text) } ?? ""
                return LyricsSearchResult(
                    songId: songId,
                    songTitle: songTitle,
                    artistName: row["artistName"], coverArt: row["coverArt"],
                    snippet: snippet,
                    duration: row["songDuration"]
                )
            }
        }) ?? []
    }

    private func extractSnippet(from text: String, query: String) -> String? {
        let lower = query.lowercased()
        return text.components(separatedBy: "\n")
            .first { $0.lowercased().contains(lower) }?
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Navidrome

    private func fetchFromNavidrome(song: Song, serverId: String) async -> LyricsRecord? {
        DBErrorLog.logLyrics("Request → Navidrome: \(song.title)")
        guard let entry = try? await SubsonicAPIService.shared.getLyricsBySongId(songId: song.id),
              let lines = entry.line, !lines.isEmpty else {
            DBErrorLog.logLyrics("No match → Navidrome: \(song.title)")
            return nil
        }

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
            songId: song.id, serverId: serverId, source: "navidrome",
            plainText: plain, syncedLrc: lrc,
            isSynced: entry.synced && lrc != nil,
            isInstrumental: false, language: entry.lang,
            fetchedAt: Date().timeIntervalSince1970,
            songTitle: song.title, artistName: song.artist, coverArt: song.coverArt
        )
    }

    // MARK: - LRCLIB

    private func fetchFromLrcLib(song: Song, serverId: String) async -> LrcLibOutcome {
        var items: [URLQueryItem] = [URLQueryItem(name: "track_name", value: song.title)]
        if let a = song.artist  { items.append(URLQueryItem(name: "artist_name", value: a)) }
        if let a = song.album   { items.append(URLQueryItem(name: "album_name",  value: a)) }
        if let d = song.duration { items.append(URLQueryItem(name: "duration",   value: "\(d)")) }
        guard let requestInfo = LrcLibEndpoint.apiRequest(queryItems: items) else {
            if LrcLibEndpoint.isCustomEnabled && !LrcLibEndpoint.isOnlineFallbackEnabled {
                DBErrorLog.logLyrics("Fallback off → LRCLIB skipped: custom URL invalid or empty")
            }
            return .indeterminate
        }
        if let fallbackReason = requestInfo.fallbackReason {
            DBErrorLog.logLyrics("Fallback → LRCLIB online: \(fallbackReason)")
        }
        let outcome = await fetchFromLrcLib(song: song, serverId: serverId, requestInfo: requestInfo)
        guard requestInfo.isCustom else { return outcome }

        let fallbackReason: String
        switch outcome {
        case .found:
            return outcome
        case .notFound:
            fallbackReason = "custom no match"
        case .indeterminate:
            fallbackReason = "custom failed"
        }

        guard LrcLibEndpoint.isOnlineFallbackEnabled else {
            DBErrorLog.logLyrics("Fallback off → LRCLIB online skipped (\(fallbackReason)): \(song.title)")
            return outcome
        }
        DBErrorLog.logLyrics("Fallback → LRCLIB online (\(fallbackReason)): \(song.title)")

        guard let onlineRequest = LrcLibEndpoint.apiRequest(queryItems: items, forceOnline: true) else {
            return outcome
        }
        return await fetchFromLrcLib(song: song, serverId: serverId, requestInfo: onlineRequest)
    }

    private func fetchFromLrcLib(song: Song, serverId: String, requestInfo: LrcLibEndpoint.RequestInfo) async -> LrcLibOutcome {
        let url = requestInfo.url
        DBErrorLog.logLyrics("Request → \(requestInfo.source): \(song.title)")

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Shelv/1.0 (https://github.com/gatzenga/Shelv)", forHTTPHeaderField: "User-Agent")

        // Retry bei transient errors (Timeout, 5xx, 429) mit exponential backoff + jitter.
        // Jitter verhindert, dass 5 parallele Bulk-Requests synchron retry'n.
        let backoffsMs: [UInt64] = [0, 400, 1500]
        var data = Data()
        var http: HTTPURLResponse?
        for (attempt, delay) in backoffsMs.enumerated() {
            if Task.isCancelled { return .indeterminate }
            if delay > 0 {
                let jitter = UInt64.random(in: 0...250)
                try? await Task.sleep(nanoseconds: (delay + jitter) * 1_000_000)
                if Task.isCancelled { return .indeterminate }
            }
            do {
                let (d, resp) = try await Self.lrcLibSession.data(for: req)
                guard let h = resp as? HTTPURLResponse else { continue }
                http = h
                data = d
                if h.statusCode == 404 {
                    DBErrorLog.logLyrics("No match → \(requestInfo.source) HTTP 404: \(song.title)")
                    return .notFound
                }
                if h.statusCode == 200 { break }
                // 429, 5xx → nächster Versuch
                DBErrorLog.logLyrics("Response → \(requestInfo.source) HTTP \(h.statusCode): \(song.title)")
                if Task.isCancelled || attempt == backoffsMs.count - 1 {
                    return .indeterminate
                }
            } catch {
                DBErrorLog.logLyrics("Error → \(requestInfo.source): \(song.title) — \(error.localizedDescription)")
                if Task.isCancelled || attempt == backoffsMs.count - 1 {
                    return .indeterminate
                }
            }
        }
        guard http?.statusCode == 200 else {
            return .indeterminate
        }

        guard let lrc = try? JSONDecoder().decode(LrcLibResponse.self, from: data) else {
            DBErrorLog.logLyrics("Invalid response → \(requestInfo.source): \(song.title)")
            return .indeterminate
        }

        if lrc.instrumental == true {
            DBErrorLog.logLyrics("Found → \(requestInfo.source): \(song.title)")
            return .found(LyricsRecord(
                songId: song.id, serverId: serverId, source: "lrclib",
                plainText: nil, syncedLrc: nil, isSynced: false,
                isInstrumental: true, language: nil,
                fetchedAt: Date().timeIntervalSince1970,
                songTitle: song.title, artistName: song.artist, coverArt: song.coverArt
            ))
        }

        guard lrc.plainLyrics != nil || lrc.syncedLyrics != nil else {
            DBErrorLog.logLyrics("No match → \(requestInfo.source): \(song.title)")
            return .notFound
        }

        DBErrorLog.logLyrics("Found → \(requestInfo.source): \(song.title)")
        return .found(LyricsRecord(
            songId: song.id, serverId: serverId, source: "lrclib",
            plainText: lrc.plainLyrics,
            syncedLrc: lrc.syncedLyrics,
            isSynced: lrc.syncedLyrics != nil,
            isInstrumental: false, language: nil,
            fetchedAt: Date().timeIntervalSince1970,
            songTitle: song.title, artistName: song.artist, coverArt: song.coverArt
        ))
    }
}
