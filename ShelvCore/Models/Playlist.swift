import Foundation

struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let comment: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    var created: Date?
    var changed: Date?
    var songs: [Song]?

    // `songs` bewusst NICHT in den CodingKeys — wird rein lokal via loadPlaylistDetail
    // befüllt, nie de-/encodiert (Listen-Response trägt keine Songs).
    enum CodingKeys: String, CodingKey {
        case id, name, comment, songCount, duration, coverArt, created, changed
    }
}

extension Playlist {
    // Custom Decoder in der Extension, damit der synthetisierte Memberwise-Init
    // erhalten bleibt (LibraryStore konstruiert Playlists direkt).
    // `created`/`changed` tolerant via FlexibleDate — Mac-API liefert ISO8601-Strings.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        songCount = try c.decodeIfPresent(Int.self, forKey: .songCount)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        created = FlexibleDate.decode(c, .created)
        changed = FlexibleDate.decode(c, .changed)
        songs = nil
    }
}
