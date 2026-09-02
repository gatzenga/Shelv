#if DEBUG
import Foundation

/// Hartkodierter Demo-Datensatz für App-Store-Screenshots.
///
/// Nur in Debug-Builds einkompiliert (`#if DEBUG`) — landet niemals in TestFlight/Release.
/// Aktiviert wird er über den Demo-Server (`DemoContent.server`), den `ServerStore` in
/// Debug-Builds in die Serverliste einfügt. Sobald dieser Server aktiv ist, liefert
/// `SubsonicAPIService` diese Daten statt echter Netzwerk-Antworten, `AlbumArtView` lädt
/// die Cover aus dem Asset-Katalog (Präfix `demo_`), und `AudioPlayerService` zeigt ein
/// festes Player-Standbild.
///
/// Single Source of Truth: alles hier ist deterministisch, also über Jahre reproduzierbar.
nonisolated enum DemoContent {

    static let serverBaseURL = "demo://shelv"
    static let serverID = UUID(uuidString: "DEC0DE00-0000-0000-0000-000000000001") ?? UUID()

    /// Fester Demo-Server. Über JSON dekodiert, damit die `id` stabil bleibt
    /// (der normale `init` würde jedes Mal eine neue UUID erzeugen).
    static let server: SubsonicServer = {
        let json = """
        {"id":"\(serverID.uuidString)","name":"Demo","baseURL":"\(serverBaseURL)","username":"demo"}
        """
        return (try? JSONDecoder().decode(SubsonicServer.self, from: Data(json.utf8)))
            ?? SubsonicServer(name: "Demo", baseURL: serverBaseURL, username: "demo")
    }()

    // MARK: - Album-Spezifikationen

    private struct AlbumSpec {
        let key: String
        let title: String
        let artistKey: String
        let artistName: String
        let year: Int
        /// OpenSubsonic release types, so the demo shows the discography filter.
        var releaseTypes: [String]? = nil
        /// Short releases reuse the cover of the artist's album, the asset
        /// catalogue holds one image per album key.
        var coverKey: String? = nil
        let tracks: [(String, Int)]   // (Titel, Sekunden)

        var albumId: String { "demo-album-\(key)" }
        var artistId: String { "demo-artist-\(artistKey)" }
        var cover: String { "demo_cover_\(coverKey ?? key)" }
    }

    private static let specs: [AlbumSpec] = [
        AlbumSpec(key: "depth_unknown", title: "Depth Unknown", artistKey: "deadlight_protocol",
                  artistName: "Deadlight Protocol", year: 2024, tracks: [
            ("Pale Horizon", 46), ("The Last Signal", 259), ("Hollow Ground", 159),
            ("Fractured Light", 224), ("Shallow Orbit", 198), ("Before the Static", 245),
            ("Drowned Out", 187), ("Depth Unknown", 312),
        ]),
        AlbumSpec(key: "after_last_light", title: "After the Last Light", artistKey: "pale_signal",
                  artistName: "Pale Signal", year: 2019, tracks: [
            ("First Light", 203), ("Business", 251), ("Quiet Hands", 178), ("Embers", 226),
            ("Slow Collapse", 264), ("Afterglow", 199), ("The Long Way Down", 288),
        ]),
        AlbumSpec(key: "drift", title: "Drift", artistKey: "noxn", artistName: "NOXN",
                  year: 2009, tracks: [
            ("Undertow", 241), ("Drift", 305), ("Glass Sea", 192), ("Northbound", 218),
            ("Static Bloom", 257), ("Low Tide", 174), ("Driftwood", 233),
        ]),
        AlbumSpec(key: "hollow_season", title: "The Hollow Season", artistKey: "threshold_nine",
                  artistName: "Threshold Nine", year: 2020, tracks: [
            ("Opening", 165), ("My Name Is", 268), ("Cold Frame", 211), ("Hollow", 247),
            ("Paper Walls", 196), ("Season's End", 279), ("Last Frost", 223),
        ]),
        AlbumSpec(key: "no_signal_left", title: "No Signal Left", artistKey: "abyss_protocol",
                  artistName: "Abyss Protocol", year: 2025, tracks: [
            ("Carrier Lost", 232), ("No Signal Left", 297), ("Dead Air", 184),
            ("Interference", 256), ("Black Box", 209), ("Silent Frequency", 271), ("Echoes", 238),
        ]),
        AlbumSpec(key: "peripheral", title: "Peripheral", artistKey: "duskwalker",
                  artistName: "Duskwalker", year: 2022, tracks: [
            ("Underpass", 217), ("Peripheral", 283), ("Neon Rain", 195), ("Late Transit", 241),
            ("Sodium Glow", 228), ("Last Stop", 262), ("Tunnel Vision", 206),
        ]),
        AlbumSpec(key: "recovery", title: "Recovery", artistKey: "void", artistName: "VOID",
                  year: 2010, tracks: [
            ("Ruins", 254), ("Recovery", 311), ("Overgrown", 198), ("Stillness", 237),
            ("Moss & Stone", 219), ("Reclaimed", 276), ("Quiet Ascent", 243),
        ]),
        AlbumSpec(key: "relapse", title: "Relapse", artistKey: "grvrd", artistName: "GRVRD",
                  year: 2021, tracks: [
            ("Relapse", 289), ("Dusk Bloom", 207), ("Soft Decay", 234), ("Violet Hour", 251),
            ("Fade Pattern", 188), ("Afterimage", 266), ("Comedown", 222),
        ]),
        AlbumSpec(key: "ruins_of_quiet", title: "Ruins of Quiet", artistKey: "remnvnt",
                  artistName: "REMNVNT", year: 2018, tracks: [
            ("Dune", 213), ("Ruins of Quiet", 298), ("Sandglass", 191), ("Heat Mirage", 245),
            ("Empty Quarter", 268), ("Goldenrod", 202), ("Last Oasis", 257),
        ]),
        AlbumSpec(key: "carrier_wave", title: "Carrier Wave", artistKey: "deadlight_protocol",
                  artistName: "Deadlight Protocol", year: 2025,
                  releaseTypes: ["single"], coverKey: "depth_unknown", tracks: [
            ("Carrier Wave", 268),
        ]),
        AlbumSpec(key: "night_watch", title: "Night Watch", artistKey: "deadlight_protocol",
                  artistName: "Deadlight Protocol", year: 2023,
                  releaseTypes: ["ep"], coverKey: "depth_unknown", tracks: [
            ("Night Watch", 241), ("Signal Drift", 197), ("Watchtower", 263),
        ]),
        AlbumSpec(key: "second_light", title: "Second Light", artistKey: "deadlight_protocol",
                  artistName: "Deadlight Protocol", year: 2021,
                  releaseTypes: ["album"], coverKey: "depth_unknown", tracks: [
            ("Second Light", 224), ("Ash Field", 251), ("Undertone", 196), ("Coastline", 268),
            ("Half Signal", 233), ("Second Dark", 289),
        ]),
        AlbumSpec(key: "quiet_hands_single", title: "Quiet Hands", artistKey: "pale_signal",
                  artistName: "Pale Signal", year: 2021,
                  releaseTypes: ["single"], coverKey: "after_last_light", tracks: [
            ("Quiet Hands (Live)", 214),
        ]),
    ]

    // MARK: - Abgeleitete Objekte

    private static func songs(for spec: AlbumSpec) -> [Song] {
        spec.tracks.enumerated().map { idx, t in
            Song(id: "\(spec.albumId)-\(idx + 1)", title: t.0, artist: spec.artistName,
                 album: spec.title, albumId: spec.albumId, track: idx + 1, discNumber: 1,
                 duration: t.1, coverArt: spec.cover, year: spec.year, genre: "Ambient",
                 playCount: max(0, 12 - idx * 2), starred: nil, suffix: "mp3",
                 bitRate: 320, replayGain: nil)
        }
    }

    private static func album(for spec: AlbumSpec) -> Album {
        let s = songs(for: spec)
        return Album(id: spec.albumId, name: spec.title, artist: spec.artistName,
                     artistId: spec.artistId, coverArt: spec.cover, songCount: s.count,
                     duration: s.reduce(0) { $0 + ($1.duration ?? 0) }, year: spec.year,
                     genre: "Ambient", playCount: s.reduce(0) { $0 + ($1.playCount ?? 0) },
                     starred: nil, created: nil, releaseTypes: spec.releaseTypes)
    }

    static let albums: [Album] = specs.map(album(for:))

    private static let songsByAlbumId: [String: [Song]] =
        Dictionary(uniqueKeysWithValues: specs.map { ($0.albumId, songs(for: $0)) })

    private static let albumById: [String: Album] =
        Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })

    static let artists: [Artist] = {
        var seen = Set<String>()
        return specs.compactMap { spec in
            guard seen.insert(spec.artistId).inserted else { return nil }
            let releases = specs.filter { $0.artistId == spec.artistId }.count
            return Artist(id: spec.artistId, name: spec.artistName, albumCount: releases,
                          coverArt: "demo_artist_\(spec.artistKey)", starred: nil)
        }
    }()

    // MARK: - API-Antworten

    static func albumDetail(id: String) -> AlbumDetail? {
        guard let a = albumById[id] else { return nil }
        return AlbumDetail(id: a.id, name: a.name, artist: a.artist, artistId: a.artistId,
                           coverArt: a.coverArt, songCount: a.songCount, duration: a.duration,
                           year: a.year, genre: a.genre, song: songsByAlbumId[id])
    }

    /// Biography and related artists for the artist page. The other demo
    /// artists stand in for what a server returns as similar artists.
    static func artistInfo(id: String, similarArtistCount: Int) -> ArtistInfo {
        let biography = artists.first(where: { $0.id == id }).map {
            "\($0.name) records slow, wide ambient pieces built from field recordings and analogue tape. "
            + "This biography is part of the demo library and does not describe a real artist."
        }
        guard similarArtistCount > 0 else {
            return ArtistInfo(biography: biography, similarArtist: nil, musicBrainzId: nil, lastFmUrl: nil)
        }
        let others = artists.filter { $0.id != id }.prefix(similarArtistCount)
        return ArtistInfo(biography: biography, similarArtist: Array(others), musicBrainzId: nil, lastFmUrl: nil)
    }

    static func artistDetail(id: String) -> ArtistDetail? {
        guard let artist = artists.first(where: { $0.id == id }) else { return nil }
        let owned = albums.filter { $0.artistId == id }
        return ArtistDetail(id: artist.id, name: artist.name, albumCount: owned.count,
                            coverArt: artist.coverArt, album: owned)
    }

    /// Discover-Listen — feste, kuratierte Reihenfolge pro Typ.
    static func albumList(type: String) -> [Album] {
        func byKeys(_ keys: [String]) -> [Album] {
            keys.compactMap { k in albums.first { $0.id == "demo-album-\(k)" } }
        }
        switch type {
        case "newest":
            return byKeys(["recovery", "hollow_season", "after_last_light", "ruins_of_quiet",
                           "no_signal_left", "drift", "peripheral", "depth_unknown", "relapse"])
        case "recent":
            return byKeys(["depth_unknown", "ruins_of_quiet", "peripheral", "no_signal_left",
                           "hollow_season", "drift", "recovery", "after_last_light", "relapse"])
        case "frequent":
            return byKeys(["depth_unknown", "recovery", "hollow_season", "drift", "peripheral",
                           "no_signal_left", "ruins_of_quiet", "after_last_light", "relapse"])
        case "random":
            return albums.shuffled()   // echte Variation bei jedem Laden der "Random Albums"
        default:
            return albums              // z.B. alphabeticalByName für die Library
        }
    }

    static let starred: StarredResult = {
        let favArtists = artists.filter { $0.id == "demo-artist-pale_signal" }
        let favAlbums = albums.filter {
            $0.id == "demo-album-depth_unknown" || $0.id == "demo-album-no_signal_left"
        }
        let favSongs = [
            songsByAlbumId["demo-album-after_last_light"]?.first { $0.title == "Business" },
            songsByAlbumId["demo-album-hollow_season"]?.first { $0.title == "My Name Is" },
        ].compactMap { $0 }
        return StarredResult(artist: favArtists, album: favAlbums, song: favSongs)
    }()

    static func search(query: String) -> SearchResult {
        let q = query.lowercased()
        guard !q.isEmpty else { return SearchResult(artist: [], album: [], song: []) }
        let allSongs = specs.flatMap { songs(for: $0) }
        return SearchResult(
            artist: artists.filter { $0.name.lowercased().contains(q) },
            album: albums.filter { $0.name.lowercased().contains(q) },
            song: allSongs.filter { $0.title.lowercased().contains(q) }
        )
    }

    // MARK: - Playlists

    private struct PlaylistSpec {
        let key: String
        let name: String
        let albumKeys: [String]   // Songs dieser Alben fließen in die Playlist
        // Navidrome erzeugt Playlist-Cover als 2×2-Mosaik aus vier Album-Covern — wird als
        // eigenes Asset `demo_playlist_<key>` vorab generiert (siehe Asset-Katalog).
        var cover: String { "demo_playlist_\(key)" }
    }

    private static let playlistSpecs: [PlaylistSpec] = [
        PlaylistSpec(key: "late-night-drive", name: "Late Night Drive",
                     albumKeys: ["peripheral", "drift", "depth_unknown", "no_signal_left"]),
        PlaylistSpec(key: "deep-focus", name: "Deep Focus",
                     albumKeys: ["recovery", "hollow_season", "ruins_of_quiet"]),
        PlaylistSpec(key: "rainy-day", name: "Rainy Day",
                     albumKeys: ["drift", "after_last_light", "relapse"]),
        PlaylistSpec(key: "midnight-ambient", name: "Midnight Ambient",
                     albumKeys: ["depth_unknown", "no_signal_left", "recovery"]),
        PlaylistSpec(key: "sunset-sessions", name: "Sunset Sessions",
                     albumKeys: ["ruins_of_quiet", "hollow_season", "relapse"]),
    ]

    private static func songs(forPlaylist spec: PlaylistSpec) -> [Song] {
        spec.albumKeys.flatMap { songsByAlbumId["demo-album-\($0)"] ?? [] }
    }

    private static var userPlaylists: [Playlist] {
        playlistSpecs.map { spec in
            let s = songs(forPlaylist: spec)
            return Playlist(id: "demo-playlist-\(spec.key)", name: spec.name, comment: nil,
                            songCount: s.count, duration: s.reduce(0) { $0 + ($1.duration ?? 0) },
                            coverArt: spec.cover)
        }
    }

    static var playlists: [Playlist] { userPlaylists }

    static func playlist(id: String) -> Playlist? {
        guard let spec = playlistSpecs.first(where: { "demo-playlist-\($0.key)" == id }) else { return nil }
        let s = songs(forPlaylist: spec)
        var p = Playlist(id: id, name: spec.name, comment: nil, songCount: s.count,
                         duration: s.reduce(0) { $0 + ($1.duration ?? 0) }, coverArt: spec.cover)
        p.songs = s
        return p
    }

    /// Meistgespielte Demo-Tracks — bewusst aus verschiedenen Alben (gemischte
    /// Cover), mit absteigenden Wiedergabezahlen. (albumKey, Track-Index 0-basiert, Plays).
    private static let mostPlayedTracks: [(String, Int, Int)] = [
        ("depth_unknown", 1, 47), ("recovery", 1, 41), ("peripheral", 1, 38),
        ("no_signal_left", 1, 33), ("hollow_season", 1, 29), ("drift", 1, 26),
        ("ruins_of_quiet", 1, 22), ("relapse", 0, 19), ("after_last_light", 1, 17),
        ("depth_unknown", 3, 14), ("recovery", 2, 12), ("peripheral", 2, 9),
        ("drift", 0, 7), ("hollow_season", 3, 5), ("no_signal_left", 4, 3),
    ]

    private static func mostPlayedTrack(_ key: String, _ idx: Int) -> Song? {
        let arr = songsByAlbumId["demo-album-\(key)"] ?? []
        return idx < arr.count ? arr[idx] : nil
    }

    static var mostPlayedSongs: [Song] { mostPlayedTracks.compactMap { mostPlayedTrack($0.0, $0.1) } }

    /// Play-Counts (ersetzt im Demo-Modus die DB-Abfrage `topSongs`).
    static func playSongCounts() -> [PlaySongCount] {
        mostPlayedTracks.compactMap { t in
            guard let s = mostPlayedTrack(t.0, t.1) else { return nil }
            return PlaySongCount(songId: s.id, count: t.2)
        }
    }

    // MARK: - Large-Library-Stressmodus

    static let largeLibraryFixtureArgument = "-shelvLargeLibraryFixture"

    static var largeLibraryFixtureAlbumCount: Int? {
        parsedLargeLibraryFixtureCount()
    }

    static var isLargeLibraryFixtureEnabled: Bool {
        largeLibraryFixtureAlbumCount != nil
    }

    private static func parsedLargeLibraryFixtureCount() -> Int? {
        let args = ProcessInfo.processInfo.arguments
        for (index, arg) in args.enumerated() {
            if arg == largeLibraryFixtureArgument,
               index + 1 < args.count,
               let count = Int(args[index + 1]) {
                return boundedLargeLibraryFixtureCount(count)
            }
            let prefix = "\(largeLibraryFixtureArgument)="
            if arg.hasPrefix(prefix),
               let count = Int(String(arg.dropFirst(prefix.count))) {
                return boundedLargeLibraryFixtureCount(count)
            }
        }

        if let raw = ProcessInfo.processInfo.environment["SHELV_LARGE_LIBRARY_FIXTURE"],
           let count = Int(raw) {
            return boundedLargeLibraryFixtureCount(count)
        }
        return nil
    }

    private static func boundedLargeLibraryFixtureCount(_ count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(count, 100_000)
    }

    static func largeLibraryAlbums(count: Int) -> [Album] {
        let albumCount = max(0, count)
        let artistCount = largeLibraryArtistCount(albumCount: albumCount)
        let baseCreated = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 UTC

        return (0..<albumCount).map { index in
            let number = index + 1
            let artistNumber = (index % artistCount) + 1
            return Album(
                id: "fixture-album-\(padded(number, width: 6))",
                name: "Album \(padded(number, width: 6))",
                artist: "Fixture Artist \(padded(artistNumber, width: 5))",
                artistId: "fixture-artist-\(padded(artistNumber, width: 5))",
                coverArt: nil,
                songCount: 10 + (index % 9),
                duration: 1_800 + (index % 1_200),
                year: 1960 + (index % 67),
                genre: fixtureGenres[index % fixtureGenres.count],
                playCount: (index * 37) % 10_000,
                starred: nil,
                created: baseCreated.addingTimeInterval(TimeInterval(index * 60))
            )
        }
    }

    static func largeLibraryArtists(albumCount: Int) -> [Artist] {
        let safeAlbumCount = max(0, albumCount)
        let artistCount = largeLibraryArtistCount(albumCount: safeAlbumCount)
        guard artistCount > 0 else { return [] }

        let baseAlbumCount = safeAlbumCount / artistCount
        let remainder = safeAlbumCount % artistCount
        return (0..<artistCount).map { index in
            let number = index + 1
            let albumsForArtist = baseAlbumCount + (index < remainder ? 1 : 0)
            return Artist(
                id: "fixture-artist-\(padded(number, width: 5))",
                name: "Fixture Artist \(padded(number, width: 5))",
                albumCount: albumsForArtist,
                coverArt: nil,
                starred: nil
            )
        }
    }

    private static func largeLibraryArtistCount(albumCount: Int) -> Int {
        guard albumCount > 0 else { return 0 }
        return min(10_000, max(1, albumCount / 10))
    }

    private static let fixtureGenres = [
        "Ambient", "Electronic", "Post-Rock", "Jazz", "Classical", "Soundtrack", "Indie", "Metal"
    ]

    private static func padded(_ value: Int, width: Int) -> String {
        String(format: "%0\(width)d", value)
    }

    // MARK: - Player-Standbild

    /// Fester Player-Zustand: "The Last Signal" aus "Depth Unknown", pausiert bei 2:46 / 4:19.
    static var playerSong: Song {
        depthUnknownSongs.first { $0.title == "The Last Signal" } ?? firstAvailableDemoSong
    }
    static var playerQueue: [Song] {
        depthUnknownSongs.isEmpty ? [firstAvailableDemoSong] : depthUnknownSongs
    }

    private static var depthUnknownSongs: [Song] {
        songsByAlbumId["demo-album-depth_unknown"] ?? []
    }

    private static var firstAvailableDemoSong: Song {
        songsByAlbumId.values.lazy.flatMap { $0 }.first ?? Song(
            id: "demo-player-fallback",
            title: "The Last Signal",
            artist: "Demo",
            album: "Demo",
            albumId: "demo-album-fallback",
            track: 1,
            discNumber: 1,
            duration: 259,
            coverArt: nil,
            year: 2024,
            genre: "Ambient",
            playCount: 0,
            starred: nil,
            suffix: "mp3",
            bitRate: 320,
            replayGain: nil
        )
    }
    static let playerCurrentIndex = 1          // "The Last Signal" ist Track 2
    static let playerCurrentTime: Double = 166 // 2:46
    static let playerDuration: Double = 259    // 4:19
}
#endif
