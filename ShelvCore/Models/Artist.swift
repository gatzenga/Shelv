import Foundation

nonisolated struct Artist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    /// OpenSubsonic's authoritative artist sort name, when supplied.
    let sortName: String?
    let albumCount: Int?
    let coverArt: String?
    var starred: Date?

    var isStarred: Bool { starred != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, sortName, albumCount, coverArt, starred
    }

    init(
        id: String,
        name: String,
        sortName: String? = nil,
        albumCount: Int? = nil,
        coverArt: String? = nil,
        starred: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.albumCount = albumCount
        self.coverArt = coverArt
        self.starred = starred
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sortName = try c.decodeIfPresent(String.self, forKey: .sortName)
        albumCount = try c.decodeIfPresent(Int.self, forKey: .albumCount)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        starred = FlexibleDate.decode(c, .starred)
    }
}
