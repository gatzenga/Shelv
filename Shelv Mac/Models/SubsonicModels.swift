import Foundation

struct ServerConfig: Codable, Equatable {
    var serverURL: String
    var username: String
    var password: String

    var isValid: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }
}

struct SubsonicServer: Identifiable, Codable {
    let id: UUID
    var name: String
    var baseURL: String
    var username: String
    var remoteUserId: String?

    var displayName: String {
        name.isEmpty ? baseURL : name
    }

    var stableId: String { remoteUserId ?? "" }

    init(name: String = "", baseURL: String, username: String) {
        self.id = UUID()
        self.name = name
        self.baseURL = baseURL
        self.username = username
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

struct Artist: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let starred: String?

    var isStarred: Bool { starred != nil }
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

struct Album: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let starred: String?
    let playCount: Int?
    let created: String?

    var isStarred: Bool { starred != nil }

    var displayYear: String {
        guard let y = year else { return "" }
        return "\(y)"
    }
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
    let starred: String?
    let song: [Song]

    var isStarred: Bool { starred != nil }
}

struct ReplayGain: Codable, Hashable {
    let trackGain: Float?
    let albumGain: Float?
    let trackPeak: Float?
    let albumPeak: Float?
}

struct Song: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let artistId: String?
    let album: String?
    let albumId: String?
    let coverArt: String?
    let duration: Int?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    var starred: String?
    let playCount: Int?
    let bitRate: Int?
    let contentType: String?
    let suffix: String?
    let replayGain: ReplayGain?

    var isStarred: Bool { starred != nil }

    var durationString: String {
        guard let d = duration else { return "--:--" }
        let m = d / 60
        let s = d % 60
        return String(format: "%d:%02d", m, s)
    }

    var displayTrack: String {
        guard let t = track else { return "" }
        return "\(t)"
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

struct Playlist: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let comment: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
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
