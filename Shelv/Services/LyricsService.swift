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
}

// MARK: - LRCLIB Response

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
        let url = Self.dbURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let p = try DatabasePool(path: url.path)
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
            m.registerMigration("v2_addSongMetadata") { db in
                try db.alter(table: "lyrics") { t in
                    t.add(column: "songTitle",  .text)
                    t.add(column: "artistName", .text)
                    t.add(column: "coverArt",   .text)
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

    nonisolated static func diskSizeBytes() -> Int {
        (try? dbURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
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

    // MARK: - Metadata Backfill

    func updateMetadata(songId: String, serverId: String, title: String, artist: String?, coverArt: String?) {
        safeWrite { db in
            try db.execute(
                sql: """
                    UPDATE lyrics SET songTitle = ?, artistName = ?, coverArt = ?
                    WHERE songId = ? AND serverId = ?
                """,
                arguments: [title, artist, coverArt, songId, serverId]
            )
        }
    }

    // MARK: - Reset

    func reset(serverId: String) {
        safeWrite { db in
            try db.execute(sql: "DELETE FROM lyrics WHERE serverId = ?", arguments: [serverId])
        }
    }

    // MARK: - Fetch & Cache

    func fetchAndSave(song: Song, serverId: String) async -> LyricsRecord {
        let sixMonths: Double = 60 * 60 * 24 * 180
        if var cached = lyrics(songId: song.id, serverId: serverId),
           Date().timeIntervalSince1970 - cached.fetchedAt < sixMonths {
            if cached.songTitle == nil || cached.artistName == nil || cached.coverArt == nil {
                cached.songTitle = cached.songTitle ?? song.title
                cached.artistName = cached.artistName ?? song.artist
                cached.coverArt = cached.coverArt ?? song.coverArt
                save(cached)
            }
            return cached
        }

        if let lrc = await fetchFromNavidrome(song: song, serverId: serverId) {
            save(lrc); return lrc
        }

        if let lrc = await fetchFromLrcLib(song: song, serverId: serverId) {
            save(lrc); return lrc
        }

        let none = LyricsRecord(
            songId: song.id, serverId: serverId, source: "none",
            plainText: nil, syncedLrc: nil, isSynced: false,
            isInstrumental: false, language: nil,
            fetchedAt: Date().timeIntervalSince1970,
            songTitle: song.title, artistName: song.artist, coverArt: song.coverArt
        )
        save(none)
        return none
    }

    // MARK: - Search

    func searchLyrics(text: String, serverId: String, limit: Int = 40) -> [LyricsSearchResult] {
        guard let pool, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let pattern = "%\(text)%"
        return (try? pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT songId, songTitle, artistName, coverArt, plainText
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
                    snippet: snippet
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
        guard let entry = try? await SubsonicAPIService.shared.getLyricsBySongId(songId: song.id),
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
            songId: song.id, serverId: serverId, source: "navidrome",
            plainText: plain, syncedLrc: lrc,
            isSynced: entry.synced && lrc != nil,
            isInstrumental: false, language: entry.lang,
            fetchedAt: Date().timeIntervalSince1970
        )
    }

    // MARK: - LRCLIB

    private func fetchFromLrcLib(song: Song, serverId: String) async -> LyricsRecord? {
        guard var comps = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        var items: [URLQueryItem] = [URLQueryItem(name: "track_name", value: song.title)]
        if let a = song.artist  { items.append(URLQueryItem(name: "artist_name", value: a)) }
        if let a = song.album   { items.append(URLQueryItem(name: "album_name",  value: a)) }
        if let d = song.duration { items.append(URLQueryItem(name: "duration",   value: "\(d)")) }
        comps.queryItems = items
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Shelv/1.0 (https://github.com/gatzenga/Shelv)", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await Self.lrcLibSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        guard let lrc = try? JSONDecoder().decode(LrcLibResponse.self, from: data) else { return nil }

        if lrc.instrumental == true {
            return LyricsRecord(
                songId: song.id, serverId: serverId, source: "lrclib",
                plainText: nil, syncedLrc: nil, isSynced: false,
                isInstrumental: true, language: nil,
                fetchedAt: Date().timeIntervalSince1970,
                songTitle: song.title, artistName: song.artist, coverArt: song.coverArt
            )
        }

        guard lrc.plainLyrics != nil || lrc.syncedLyrics != nil else { return nil }

        return LyricsRecord(
            songId: song.id, serverId: serverId, source: "lrclib",
            plainText: lrc.plainLyrics,
            syncedLrc: lrc.syncedLyrics,
            isSynced: lrc.syncedLyrics != nil,
            isInstrumental: false, language: nil,
            fetchedAt: Date().timeIntervalSince1970,
            songTitle: song.title, artistName: song.artist, coverArt: song.coverArt
        )
    }
}
