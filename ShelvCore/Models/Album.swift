import Foundation

struct Album: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let playCount: Int?
    var starred: Date?
    let created: Date?
    var songs: [Song]?

    var isStarred: Bool { starred != nil }

    var displayYear: String {
        guard let y = year else { return "" }
        return "\(y)"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, artist, artistId, coverArt, songCount, duration, year, genre, playCount, starred, created
    }

    init(
        id: String,
        name: String,
        artist: String? = nil,
        artistId: String? = nil,
        coverArt: String? = nil,
        songCount: Int? = nil,
        duration: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        playCount: Int? = nil,
        starred: Date? = nil,
        created: Date? = nil,
        songs: [Song]? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.coverArt = coverArt
        self.songCount = songCount
        self.duration = duration
        self.year = year
        self.genre = genre
        self.playCount = playCount
        self.starred = starred
        self.created = created
        self.songs = songs
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
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount)
        starred = FlexibleDate.decode(c, .starred)
        created = FlexibleDate.decode(c, .created)
        songs = nil
    }
}
