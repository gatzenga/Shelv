import SwiftUI

enum AlbumSortOption: String, CaseIterable {
    case alphabetical = "alphabeticalByName"
    case frequent     = "frequent"
    case newest       = "newest"
    case year         = "year"

    var label: String {
        switch self {
        case .alphabetical: return String(localized: "name")
        case .frequent:     return String(localized: "most_played")
        case .newest:       return String(localized: "recently_added")
        case .year:         return String(localized: "year")
        }
    }

    var requiresServer: Bool { self == .frequent || self == .newest }
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
    private nonisolated static let sortArticles: [String] = [
        "the ", "an ", "a ",
        "der ", "die ", "das ", "dem ", "den ", "des ",
        "eine ", "einer ", "einem ", "einen ", "ein ",
        "les ", "le ", "la ", "l\u{2019}", "l'",
        "une ", "des ", "un ",
        "los ", "las ", "el ", "una ", "un ",
        "gli ", "uno ", "una ", "il ", "lo ", "un ",
        "umas ", "uma ", "uns ", "um ", "os ", "as ",
        "het ", "een ", "de ",
    ]

    private nonisolated static func sortKey(for name: String) -> String {
        let lower = name.lowercased()
        for article in sortArticles {
            if lower.hasPrefix(article) {
                return String(name.dropFirst(article.count))
            }
        }
        return name
    }

    nonisolated static func groupByFirstLetter<T>(
        _ items: [T],
        name: KeyPath<T, String>
    ) -> [(letter: String, items: [T])] {
        var dict: [String: [T]] = [:]
        for item in items {
            let key = sortKey(for: item[keyPath: name])
            let raw = String(key.prefix(1))
            let base = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
            let letter = (base.first?.isLetter == true) ? String(base.prefix(1)) : "#"
            dict[letter, default: []].append(item)
        }
        let letters = dict.keys.sorted {
            if $0 == "#" { return true }
            if $1 == "#" { return false }
            return $0 < $1
        }
        return letters.map { ($0, dict[$0, default: []]) }
    }
}
