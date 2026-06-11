#if DEBUG
import Foundation

enum DemoContent {

    static let serverBaseURL = "demo://shelv"
    static let serverID = UUID(uuidString: "DEC0DE00-0000-0000-0000-000000000001")!

    static let server: SubsonicServer = {
        let json = """
        {"id":"\(serverID.uuidString)","name":"Demo","baseURL":"\(serverBaseURL)","username":"demo"}
        """
        return try! JSONDecoder().decode(SubsonicServer.self, from: Data(json.utf8))
    }()

    private struct AlbumSpec {
        let key: String
        let title: String
        let artistKey: String
        let artistName: String
        let year: Int
        let tracks: [(String, Int)]

        var albumId: String { "demo-album-\(key)" }
        var artistId: String { "demo-artist-\(artistKey)" }
        var cover: String { "demo_cover_\(key)" }
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
    ]

    private static func songs(for spec: AlbumSpec) -> [Song] {
        spec.tracks.enumerated().map { idx, t in
            Song(id: "\(spec.albumId)-\(idx + 1)", title: t.0, artist: spec.artistName,
                 artistId: spec.artistId, album: spec.title, albumId: spec.albumId,
                 track: idx + 1, discNumber: 1, duration: t.1,
                 coverArt: spec.cover, year: spec.year, genre: "Ambient",
                 playCount: max(0, 12 - idx * 2),
                 contentType: "audio/mpeg", suffix: "mp3", bitRate: 320)
        }
    }

    private static func album(for spec: AlbumSpec) -> Album {
        let s = songs(for: spec)
        return Album(id: spec.albumId, name: spec.title, artist: spec.artistName,
                     artistId: spec.artistId, coverArt: spec.cover, songCount: s.count,
                     duration: s.reduce(0) { $0 + ($1.duration ?? 0) }, year: spec.year,
                     genre: "Ambient",
                     playCount: s.reduce(0) { $0 + ($1.playCount ?? 0) })
    }

    static let albums: [Album] = specs.map(album(for:))

    private static let songsByAlbumId: [String: [Song]] =
        Dictionary(uniqueKeysWithValues: specs.map { ($0.albumId, songs(for: $0)) })

    private static let albumById: [String: Album] =
        Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })

    static let artists: [Artist] = specs.map { spec in
        Artist(id: spec.artistId, name: spec.artistName, albumCount: 1,
               coverArt: "demo_artist_\(spec.artistKey)", starred: nil)
    }

    static func albumDetail(id: String) -> AlbumDetail? {
        guard let a = albumById[id] else { return nil }
        return AlbumDetail(id: a.id, name: a.name, artist: a.artist, artistId: a.artistId,
                           coverArt: a.coverArt, songCount: a.songCount, duration: a.duration,
                           year: a.year, genre: a.genre, starred: nil, song: songsByAlbumId[id] ?? [])
    }

    static func artistDetail(id: String) -> ArtistDetail? {
        guard let artist = artists.first(where: { $0.id == id }) else { return nil }
        let owned = albums.filter { $0.artistId == id }
        return ArtistDetail(id: artist.id, name: artist.name, albumCount: owned.count,
                            coverArt: artist.coverArt, album: owned)
    }

    static func albumList(type: AlbumListType) -> [Album] {
        func byKeys(_ keys: [String]) -> [Album] {
            keys.compactMap { k in albums.first { $0.id == "demo-album-\(k)" } }
        }
        switch type {
        case .newest:
            return byKeys(["no_signal_left", "depth_unknown", "peripheral", "relapse",
                           "hollow_season", "after_last_light", "ruins_of_quiet", "recovery", "drift"])
        case .recentlyPlayed:
            return byKeys(["depth_unknown", "ruins_of_quiet", "peripheral", "no_signal_left",
                           "hollow_season", "drift", "recovery", "relapse", "after_last_light"])
        case .frequent:
            return byKeys(["depth_unknown", "recovery", "hollow_season", "drift", "peripheral",
                           "no_signal_left", "ruins_of_quiet", "after_last_light", "relapse"])
        case .random:
            return albums.shuffled()
        default:
            return albums
        }
    }

    static let starred: Starred2Result = {
        let favArtists = artists.filter { $0.id == "demo-artist-pale_signal" }
        let favAlbums = albums.filter {
            $0.id == "demo-album-depth_unknown" || $0.id == "demo-album-no_signal_left"
        }
        let favSongs = [
            songsByAlbumId["demo-album-after_last_light"]?.first { $0.title == "Business" },
            songsByAlbumId["demo-album-hollow_season"]?.first { $0.title == "My Name Is" },
        ].compactMap { $0 }
        return Starred2Result(artist: favArtists, album: favAlbums, song: favSongs)
    }()

    static func search(query: String) -> SearchResult3 {
        let q = query.lowercased()
        guard !q.isEmpty else { return SearchResult3(artist: [], album: [], song: []) }
        let allSongs = specs.flatMap { songs(for: $0) }
        return SearchResult3(
            artist: artists.filter { $0.name.lowercased().contains(q) },
            album: albums.filter { $0.name.lowercased().contains(q) },
            song: allSongs.filter { $0.title.lowercased().contains(q) }
        )
    }

    private struct PlaylistSpec {
        let key: String
        let name: String
        let albumKeys: [String]
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

    static var playlists: [Playlist] { userPlaylists + recapPlaylists }

    static func playlistDetail(id: String) -> PlaylistDetail? {
        if id.hasPrefix("demo-recap-") {
            let s = recapTopSongs
            return PlaylistDetail(id: id, name: "Recap", comment: nil, songCount: s.count,
                                  duration: s.reduce(0) { $0 + ($1.duration ?? 0) },
                                  coverArt: "demo_cover_depth_unknown", songs: s)
        }
        guard let spec = playlistSpecs.first(where: { "demo-playlist-\($0.key)" == id }) else { return nil }
        let s = songs(forPlaylist: spec)
        return PlaylistDetail(id: id, name: spec.name, comment: nil, songCount: s.count,
                              duration: s.reduce(0) { $0 + ($1.duration ?? 0) },
                              coverArt: spec.cover, songs: s)
    }

    private static func ts(_ y: Int, _ mo: Int, _ d: Int) -> Double {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!.timeIntervalSince1970
    }

    private static func recap(_ key: String, _ period: String,
                              _ sY: Int, _ sM: Int, _ sD: Int,
                              _ eY: Int, _ eM: Int, _ eD: Int) -> RecapRegistryRecord {
        RecapRegistryRecord(playlistId: "demo-recap-\(key)", serverId: serverID.uuidString,
                            periodType: period, periodStart: ts(sY, sM, sD), periodEnd: ts(eY, eM, eD),
                            ckRecordName: nil, isTest: false)
    }

    static let recapEntries: [RecapRegistryRecord] = [
        recap("week-1", "week", 2026, 4, 27, 2026, 5, 3),
        recap("week-2", "week", 2026, 4, 20, 2026, 4, 26),
        recap("month-apr", "month", 2026, 4, 15, 2026, 4, 15),
        recap("month-mar", "month", 2026, 3, 15, 2026, 3, 15),
        recap("month-feb", "month", 2026, 2, 15, 2026, 2, 15),
        recap("month-jan", "month", 2026, 1, 15, 2026, 1, 15),
        recap("year-2025", "year", 2025, 6, 15, 2025, 6, 15),
    ]

    static var recapPlaylists: [Playlist] {
        let s = recapTopSongs
        return recapEntries.map {
            Playlist(id: $0.playlistId, name: "Recap", comment: nil, songCount: s.count,
                     duration: s.reduce(0) { $0 + ($1.duration ?? 0) }, coverArt: "demo_cover_depth_unknown")
        }
    }

    private static let recapTracks: [(String, Int, Int)] = [
        ("depth_unknown", 1, 47), ("recovery", 1, 41), ("peripheral", 1, 38),
        ("no_signal_left", 1, 33), ("hollow_season", 1, 29), ("drift", 1, 26),
        ("ruins_of_quiet", 1, 22), ("relapse", 0, 19), ("after_last_light", 1, 17),
        ("depth_unknown", 3, 14), ("recovery", 2, 12), ("peripheral", 2, 9),
        ("drift", 0, 7), ("hollow_season", 3, 5), ("no_signal_left", 4, 3),
    ]

    private static func recapTrack(_ key: String, _ idx: Int) -> Song? {
        let arr = songsByAlbumId["demo-album-\(key)"] ?? []
        return idx < arr.count ? arr[idx] : nil
    }

    static var recapTopSongs: [Song] { recapTracks.compactMap { recapTrack($0.0, $0.1) } }

    static func recapSongCounts() -> [RecapSongCount] {
        recapTracks.compactMap { t in
            guard let s = recapTrack(t.0, t.1) else { return nil }
            return RecapSongCount(songId: s.id, count: t.2)
        }
    }

    static var playerSong: Song {
        songsByAlbumId["demo-album-depth_unknown"]!.first { $0.title == "The Last Signal" }!
    }
    static var playerQueue: [Song] { songsByAlbumId["demo-album-depth_unknown"]! }
    static let playerCurrentIndex = 1
    static let playerCurrentTime: Double = 166
    static let playerDuration: Double = 259
}
#endif
