import SwiftUI

enum AlbumSortOption: String, CaseIterable {
    case alphabetical = "alphabeticalByName"
    case artist       = "artist"
    case frequent     = "frequent"
    case newest       = "newest"
    case year         = "year"

    var label: String {
        switch self {
        case .alphabetical: return String(localized: "name")
        case .artist:       return String(localized: "artist")
        case .frequent:     return String(localized: "most_played")
        case .newest:       return String(localized: "recently_added")
        case .year:         return String(localized: "year")
        }
    }

    var requiresServer: Bool { self == .frequent || self == .newest }

    nonisolated var allowsDirection: Bool { self != .alphabetical && self != .artist }
}

enum ArtistSortOption: String, CaseIterable {
    case alphabetical, frequent

    var label: String {
        switch self {
        case .alphabetical: return String(localized: "name")
        case .frequent:     return String(localized: "most_played")
        }
    }

    var requiresServer: Bool { self == .frequent }
}

enum SortDirection: String, CaseIterable {
    case ascending, descending

    var label: String {
        switch self {
        case .ascending:  return String(localized: "ascending")
        case .descending: return String(localized: "descending")
        }
    }
}

enum LibrarySegment: Int {
    case albums, artists, favorites
}

enum LibraryGrouping {
    nonisolated static func groupByFirstLetter<T>(
        _ items: [T],
        name: KeyPath<T, String>,
        sortName: KeyPath<T, String?>
    ) -> [(letter: String, items: [T])] {
        var dict: [String: [T]] = [:]
        for item in items {
            let letter = LibrarySortKey.sectionLetter(
                displayName: item[keyPath: name],
                explicitSortName: item[keyPath: sortName]
            )
            dict[letter, default: []].append(item)
        }
        let letters = dict.keys.sorted {
            if $0 == "#" { return true }
            if $1 == "#" { return false }
            return $0 < $1
        }
        return letters.map { ($0, dict[$0, default: []]) }
    }

    nonisolated static func groupAlbumsByArtistFirstLetter(
        _ albums: [Album]
    ) -> [(letter: String, items: [Album])] {
        var dict: [String: [Album]] = [:]
        for album in albums {
            let letter = LibrarySortKey.sectionLetter(displayName: album.artist ?? "")
            dict[letter, default: []].append(album)
        }
        let letters = dict.keys.sorted {
            if $0 == "#" { return true }
            if $1 == "#" { return false }
            return $0 < $1
        }
        return letters.map { ($0, dict[$0, default: []]) }
    }
}
