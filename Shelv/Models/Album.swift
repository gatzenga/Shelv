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
    let starred: Date?
    var songs: [Song]?

    enum CodingKeys: String, CodingKey {
        case id, name, artist, artistId, coverArt, songCount, duration, year, genre, starred
    }
}
