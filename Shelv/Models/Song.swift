import Foundation

struct Song: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let albumId: String?
    let track: Int?
    let duration: Int?
    let coverArt: String?
    let year: Int?
    let genre: String?
    let playCount: Int?

    var durationFormatted: String {
        guard let d = duration else { return "" }
        let m = d / 60
        let s = d % 60
        return String(format: "%d:%02d", m, s)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, albumId, track, duration, coverArt, year, genre, playCount
    }
}
