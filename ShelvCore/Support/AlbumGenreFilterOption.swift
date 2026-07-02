import Foundation

nonisolated struct AlbumGenreFilterOption: Identifiable, Hashable, Sendable {
    let name: String
    let albumCount: Int

    var id: String { Self.normalizedKey(name) }
    var label: String { "\(name) (\(albumCount))" }

    nonisolated static func options(from albums: [Album]) -> [AlbumGenreFilterOption] {
        var counts: [String: (name: String, count: Int)] = [:]
        for album in albums {
            guard let genre = normalizedGenre(album.genre) else { continue }
            let key = normalizedKey(genre)
            if let existing = counts[key] {
                counts[key] = (existing.name, existing.count + 1)
            } else {
                counts[key] = (genre, 1)
            }
        }

        return counts.values
            .map { AlbumGenreFilterOption(name: $0.name, albumCount: $0.count) }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    nonisolated static func matches(_ album: Album, selectedGenre: String) -> Bool {
        guard let genre = normalizedGenre(album.genre) else { return false }
        return normalizedKey(genre) == normalizedKey(selectedGenre)
    }

    nonisolated static func selectedGenre(_ value: String?, in options: [AlbumGenreFilterOption]) -> String? {
        guard let genre = normalizedGenre(value) else { return nil }
        let key = normalizedKey(genre)
        return options.first { $0.id == key }?.name
    }

    nonisolated static func normalizedGenre(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
