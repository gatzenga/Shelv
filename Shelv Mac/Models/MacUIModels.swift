import Foundation

// Kern-Modelle (Song, Album, Artist, Playlist, SubsonicServer, ReplayGain)
// leben seit der Target-Zusammenführung in ShelvCore/Models/.
// Hier verbleiben: der ServerConfig-Pfad + Response-Wrapper des (noch)
// macOS-eigenen SubsonicAPIService [TODO(W3): mit iOS-API zusammenführen]
// sowie macOS-spezifische UI-Enums und Player-Typen.

struct ServerConfig: Codable, Equatable {
    var serverURL: String
    var username: String
    var password: String

    var isValid: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }
}

struct SubsonicResponse: Codable {
    let subsonicResponse: SubsonicResponseBody

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct SubsonicResponseBody: Codable {
    let status: String
    let version: String
    let serverVersion: String?
    let type: String?
    let error: SubsonicError?
    let artists: ArtistsResult?
    let artist: ArtistDetail?
    let albumList2: AlbumListResult?
    let album: AlbumDetail?
    let randomSongs: RandomSongsResult?
    let topSongs: RandomSongsResult?
    let searchResult3: SearchResult3?
    let starred2: Starred2Result?
    let scanStatus: ScanStatusBody?
    let playlists: PlaylistsResult?
    let playlist: PlaylistDetail?
    let lyricsList: LyricsListBody?
    let song: Song?
    let artistInfo2: ArtistInfo?
}

struct ArtistInfo: Codable {
    let biography: String?
}

struct LyricsListBody: Codable {
    let structuredLyrics: [StructuredLyrics]?
}

struct StructuredLyrics: Codable {
    let synced: Bool
    let lang: String?
    let line: [LyricsLine]?

    struct LyricsLine: Codable {
        let start: Int?
        let value: String
    }
}

struct ScanStatusBody: Codable {
    let scanning: Bool
    let count: Int?
}

struct SubsonicError: Codable {
    let code: Int
    let message: String
}

struct ArtistsResult: Codable {
    let index: [ArtistIndex]
}

struct ArtistIndex: Codable, Identifiable {
    // We use `name` (the letter, e.g. "A") as the stable identifier.
    var id: String { name }
    let name: String
    let artist: [Artist]

    enum CodingKeys: String, CodingKey {
        case name, artist
    }
}

struct ArtistDetail: Codable, Identifiable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let album: [Album]
}

struct AlbumListResult: Codable {
    let album: [Album]
}

struct AlbumDetail: Codable, Identifiable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let starred: Date?
    let song: [Song]

    var isStarred: Bool { starred != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, artist, artistId, coverArt, songCount, duration, year, genre, starred, song
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        songCount = try c.decodeIfPresent(Int.self, forKey: .songCount)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        starred = FlexibleDate.decode(c, .starred)
        song = try c.decodeIfPresent([Song].self, forKey: .song) ?? []
    }

    init(id: String, name: String, artist: String? = nil, artistId: String? = nil,
         coverArt: String? = nil, songCount: Int? = nil, duration: Int? = nil,
         year: Int? = nil, genre: String? = nil, starred: Date? = nil, song: [Song]) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.coverArt = coverArt
        self.songCount = songCount
        self.duration = duration
        self.year = year
        self.genre = genre
        self.starred = starred
        self.song = song
    }
}

struct RandomSongsResult: Codable {
    let song: [Song]
}

struct SearchResult3: Codable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

struct Starred2Result: Codable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

struct PlaylistDetail: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let comment: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    let songs: [Song]?

    enum CodingKeys: String, CodingKey {
        case id, name, comment, songCount, duration, coverArt
        case songs = "entry"
    }
}

struct PlaylistsResult: Codable {
    let playlist: [Playlist]?
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case discover = "discover"
    case albums = "albums"
    case artists = "artists"
    case favorites = "favorites"
    case search = "search"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .discover: return String(localized: "discover")
        case .albums:   return String(localized: "albums")
        case .artists:  return String(localized: "artists")
        case .favorites: return String(localized: "favorites")
        case .search:   return String(localized: "search")
        }
    }

    var icon: String {
        switch self {
        case .discover: return "sparkles"
        case .albums: return "square.grid.2x2"
        case .artists: return "music.mic"
        case .favorites: return "heart"
        case .search: return "magnifyingglass"
        }
    }
}

enum LibrarySortOption: String, CaseIterable {
    case name = "name"
    case mostPlayed = "mostPlayed"
    case recentlyAdded = "recentlyAdded"
    case year = "year"

    var label: String {
        switch self {
        case .name:          return String(localized: "name")
        case .mostPlayed:    return String(localized: "most_played")
        case .recentlyAdded: return String(localized: "recently_added")
        case .year:          return String(localized: "year")
        }
    }

    var naturalDirection: SortDirection {
        self == .name ? .ascending : .descending
    }

    var requiresServer: Bool { self == .mostPlayed || self == .recentlyAdded }
}

enum ArtistSortOption: String, CaseIterable {
    case name = "name"
    case mostPlayed = "mostPlayed"

    var label: String {
        switch self {
        case .name:       return String(localized: "name")
        case .mostPlayed: return String(localized: "most_played")
        }
    }

    var requiresServer: Bool { self == .mostPlayed }

    var naturalDirection: SortDirection {
        self == .name ? .ascending : .descending
    }
}

enum SortDirection: String, CaseIterable {
    case ascending, descending

    var label: String {
        switch self {
        case .ascending:  return String(localized: "ascending")
        case .descending: return String(localized: "descending")
        }
    }
}

struct QueueItem: Identifiable, Equatable {
    let id: String
    var song: Song

    init(song: Song) {
        self.id = UUID().uuidString
        self.song = song
    }
}

enum RepeatMode: CaseIterable {
    case off, all, one

    var nextMode: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var systemImage: String {
        switch self {
        case .off:  return "repeat"
        case .all:  return "repeat"
        case .one:  return "repeat.1"
        }
    }
}
