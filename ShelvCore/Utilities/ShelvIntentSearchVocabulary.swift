import Foundation

/// Normalizes natural-language media requests into a small, deterministic set
/// of Navidrome search terms. The full query is always retained, while common
/// Siri command words are removed from supplemental terms.
nonisolated enum ShelvIntentSearchVocabulary {
    private static let stopWords: Set<String> = [
        // English
        "a", "all", "an", "and", "album", "albums", "artist", "artists", "by",
        "from", "in", "library", "me", "music", "my", "of", "on", "play", "please",
        "radio", "shelv", "shuffle", "shuffled", "song", "songs", "station", "the", "track",
        "tracks", "using", "with",
        // German
        "alle", "album", "alben", "auf", "aus", "bitte", "das", "dem", "den", "der",
        "die", "eine", "einem", "einen", "einer", "gemischt", "in", "künstler", "lied",
        "lieder", "mediathek", "meine", "meinem", "meinen", "meiner", "mit", "musik",
        "radio", "sender", "shelv", "shuffle", "spiele", "spielen", "spiel", "titel", "von"
    ]

    static func searchTerms(for rawQuery: String, maximumCount: Int = 6) -> [String] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maximumCount > 0 else { return [] }

        var terms: [String] = []
        appendUnique(trimmed, to: &terms)

        let normalizedWords = words(in: trimmed)
        let meaningfulWords = normalizedWords.filter { !stopWords.contains(normalizedKey($0)) }
        appendUnique(meaningfulWords.joined(separator: " "), to: &terms)

        for separator in [" by ", " from ", " von "] {
            let lowercased = " \(trimmed.lowercased()) "
            guard let range = lowercased.range(of: separator) else { continue }
            let lowerBoundOffset = lowercased.distance(from: lowercased.startIndex, to: range.lowerBound) - 1
            let upperBoundOffset = lowercased.distance(from: lowercased.startIndex, to: range.upperBound) - 1
            let prefix = String(trimmed.prefix(max(0, lowerBoundOffset)))
            let suffix = String(trimmed.dropFirst(max(0, upperBoundOffset)))
            appendUnique(words(in: prefix).filter { !stopWords.contains(normalizedKey($0)) }.joined(separator: " "), to: &terms)
            appendUnique(words(in: suffix).filter { !stopWords.contains(normalizedKey($0)) }.joined(separator: " "), to: &terms)
        }

        for word in meaningfulWords where normalizedKey(word).count > 1 {
            appendUnique(word, to: &terms)
            if terms.count >= maximumCount { break }
        }
        return Array(terms.prefix(maximumCount))
    }

    static func normalized(_ value: String) -> String {
        words(in: value)
            .map(normalizedKey)
            .joined(separator: " ")
    }

    private static func words(in value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normalizedKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = normalized(trimmed)
        guard !key.isEmpty, !values.contains(where: { normalized($0) == key }) else { return }
        values.append(trimmed)
    }
}
