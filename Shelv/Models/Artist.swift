import Foundation

struct Artist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, albumCount, coverArt
    }
}
