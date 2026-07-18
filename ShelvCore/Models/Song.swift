import Foundation

nonisolated struct ReplayGain: Codable, Hashable, Sendable {
    let trackGain: Float?
    let albumGain: Float?
    let trackPeak: Float?
    let albumPeak: Float?
    let baseGain: Float?
}

nonisolated struct SongGenre: Codable, Hashable, Sendable {
    let name: String
}

nonisolated struct SongContributor: Codable, Hashable, Sendable {
    let role: String
    let subRole: String?
    let artist: Artist
}

nonisolated struct SongWork: Codable, Hashable, Sendable {
    let name: String
    let musicBrainzId: String?
}

nonisolated struct SongMovement: Codable, Hashable, Sendable {
    let name: String
    let number: Int?
    let count: Int?
}

nonisolated struct Song: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String?
    let artistId: String?
    let album: String?
    let albumId: String?
    let track: Int?
    let discNumber: Int?
    let duration: Int?
    let coverArt: String?
    let year: Int?
    let genre: String?
    let playCount: Int?
    var starred: Date?
    let contentType: String?
    let suffix: String?
    let fileSize: Int64?
    let bitRate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let channelCount: Int?
    let bpm: Int?
    let comment: String?
    let musicBrainzId: String?
    let isrc: [String]?
    let genres: [SongGenre]?
    let artists: [Artist]?
    let displayArtist: String?
    let albumArtists: [Artist]?
    let displayAlbumArtist: String?
    let contributors: [SongContributor]?
    let displayComposer: String?
    let moods: [String]?
    let explicitStatus: String?
    let works: [SongWork]?
    let movements: [SongMovement]?
    let groupings: [String]?
    let replayGain: ReplayGain?

    var isStarred: Bool { starred != nil }

    var durationFormatted: String {
        guard let d = duration else { return "" }
        let m = d / 60
        let s = d % 60
        return String(format: "%d:%02d", m, s)
    }

    /// macOS-Konvention: Platzhalter statt leerem String.
    var durationString: String {
        duration == nil ? "--:--" : durationFormatted
    }

    var displayTrack: String {
        guard let t = track else { return "" }
        return "\(t)"
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, artistId, album, albumId, track, discNumber, duration, coverArt, year, genre, playCount, starred, contentType, suffix, fileSize = "size", bitRate, bitDepth, samplingRate, channelCount, bpm, comment, musicBrainzId, isrc, genres, artists, displayArtist, albumArtists, displayAlbumArtist, contributors, displayComposer, moods, explicitStatus, works, movements, groupings, replayGain
    }

    init(
        id: String,
        title: String,
        artist: String? = nil,
        artistId: String? = nil,
        album: String? = nil,
        albumId: String? = nil,
        track: Int? = nil,
        discNumber: Int? = nil,
        duration: Int? = nil,
        coverArt: String? = nil,
        year: Int? = nil,
        genre: String? = nil,
        playCount: Int? = nil,
        starred: Date? = nil,
        contentType: String? = nil,
        suffix: String? = nil,
        fileSize: Int64? = nil,
        bitRate: Int? = nil,
        bitDepth: Int? = nil,
        samplingRate: Int? = nil,
        channelCount: Int? = nil,
        bpm: Int? = nil,
        comment: String? = nil,
        musicBrainzId: String? = nil,
        isrc: [String]? = nil,
        genres: [SongGenre]? = nil,
        artists: [Artist]? = nil,
        displayArtist: String? = nil,
        albumArtists: [Artist]? = nil,
        displayAlbumArtist: String? = nil,
        contributors: [SongContributor]? = nil,
        displayComposer: String? = nil,
        moods: [String]? = nil,
        explicitStatus: String? = nil,
        works: [SongWork]? = nil,
        movements: [SongMovement]? = nil,
        groupings: [String]? = nil,
        replayGain: ReplayGain? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.album = album
        self.albumId = albumId
        self.track = track
        self.discNumber = discNumber
        self.duration = duration
        self.coverArt = coverArt
        self.year = year
        self.genre = genre
        self.playCount = playCount
        self.starred = starred
        self.contentType = contentType
        self.suffix = suffix
        self.fileSize = fileSize
        self.bitRate = bitRate
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.channelCount = channelCount
        self.bpm = bpm
        self.comment = comment
        self.musicBrainzId = musicBrainzId
        self.isrc = isrc
        self.genres = genres
        self.artists = artists
        self.displayArtist = displayArtist
        self.albumArtists = albumArtists
        self.displayAlbumArtist = displayAlbumArtist
        self.contributors = contributors
        self.displayComposer = displayComposer
        self.moods = moods
        self.explicitStatus = explicitStatus
        self.works = works
        self.movements = movements
        self.groupings = groupings
        self.replayGain = replayGain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount)
        starred = FlexibleDate.decode(c, .starred)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize)
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate)
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth)
        samplingRate = try c.decodeIfPresent(Int.self, forKey: .samplingRate)
        channelCount = try c.decodeIfPresent(Int.self, forKey: .channelCount)
        bpm = try c.decodeIfPresent(Int.self, forKey: .bpm)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        musicBrainzId = try c.decodeIfPresent(String.self, forKey: .musicBrainzId)
        isrc = try c.decodeIfPresent([String].self, forKey: .isrc)
        genres = try c.decodeIfPresent([SongGenre].self, forKey: .genres)
        artists = try c.decodeIfPresent([Artist].self, forKey: .artists)
        displayArtist = try c.decodeIfPresent(String.self, forKey: .displayArtist)
        albumArtists = try c.decodeIfPresent([Artist].self, forKey: .albumArtists)
        displayAlbumArtist = try c.decodeIfPresent(String.self, forKey: .displayAlbumArtist)
        contributors = try c.decodeIfPresent([SongContributor].self, forKey: .contributors)
        displayComposer = try c.decodeIfPresent(String.self, forKey: .displayComposer)
        moods = try c.decodeIfPresent([String].self, forKey: .moods)
        explicitStatus = try c.decodeIfPresent(String.self, forKey: .explicitStatus)
        works = try c.decodeIfPresent([SongWork].self, forKey: .works)
        movements = try c.decodeIfPresent([SongMovement].self, forKey: .movements)
        groupings = try c.decodeIfPresent([String].self, forKey: .groupings)
        replayGain = try c.decodeIfPresent(ReplayGain.self, forKey: .replayGain)
    }
}

/// Identifies a song occurrence as well as its server ID.
/// Playlists may contain the same song more than once, so `Song.id` alone is
/// not a stable identity for an individual list row.
nonisolated struct IndexedSongOccurrence: Identifiable, Hashable, Sendable {
    nonisolated struct ID: Hashable, Sendable {
        let songID: String
        let occurrence: Int
    }

    let index: Int
    let song: Song
    let occurrence: Int

    var id: ID { ID(songID: song.id, occurrence: occurrence) }

    static func rows(for songs: [Song]) -> [IndexedSongOccurrence] {
        var occurrences: [String: Int] = [:]
        return songs.enumerated().map { index, song in
            let occurrence = occurrences[song.id, default: 0]
            occurrences[song.id] = occurrence + 1
            return IndexedSongOccurrence(index: index, song: song, occurrence: occurrence)
        }
    }
}
