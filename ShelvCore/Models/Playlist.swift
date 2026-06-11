import Foundation

struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let comment: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    var songs: [Song]?

    enum CodingKeys: String, CodingKey {
        case id, name, comment, songCount, duration, coverArt
    }
}
