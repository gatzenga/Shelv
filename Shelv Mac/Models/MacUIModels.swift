import Foundation

// Kern-Modelle (Song, Album, Artist, Playlist, SubsonicServer, ReplayGain) und
// alle API-Response-Typen leben in ShelvCore. Hier verbleiben nur noch
// macOS-spezifische Typen: der ServerConfig-Login-Pfad, der gecachte
// PlaylistDetail-Typ sowie UI-Enums und Player-Typen der Desktop-Oberfläche.

struct ServerConfig: Codable, Equatable {
    var serverURL: String
    var username: String
    var password: String

    var isValid: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }
}

/// macOS-Detail-Typ für Playlists — wird auf Disk gecacht (CodingKey `entry`
/// hält das Format kompatibel zu den bestehenden Cache-Dateien der alten App).
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

    init(id: String, name: String, comment: String?, songCount: Int?,
         duration: Int?, coverArt: String?, songs: [Song]?) {
        self.id = id
        self.name = name
        self.comment = comment
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
        self.songs = songs
    }

    /// Konvertiert das geteilte Playlist-Modell (getPlaylist liefert songs mit).
    init(_ playlist: Playlist) {
        self.init(id: playlist.id, name: playlist.name, comment: playlist.comment,
                  songCount: playlist.songCount, duration: playlist.duration,
                  coverArt: playlist.coverArt, songs: playlist.songs)
    }
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

// QueueItem und RepeatMode sind mit der Player-Konsolidierung entfallen:
// die Queue ist jetzt [Song], RepeatMode liefert ShelvCore/AudioPlayerService.
