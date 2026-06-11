import Foundation

struct ReplayGain: Codable, Hashable {
    let trackGain: Float?
    let albumGain: Float?
    let trackPeak: Float?
    let albumPeak: Float?
}

struct Song: Identifiable, Codable, Hashable {
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
    let bitRate: Int?
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
        case id, title, artist, artistId, album, albumId, track, discNumber, duration, coverArt, year, genre, playCount, starred, contentType, suffix, bitRate, replayGain
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
        bitRate: Int? = nil,
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
        self.bitRate = bitRate
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
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate)
        replayGain = try c.decodeIfPresent(ReplayGain.self, forKey: .replayGain)
    }
}
