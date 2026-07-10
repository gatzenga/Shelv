import Foundation

/// Normalizes natural-language media requests into a small, deterministic set
/// of Navidrome search terms. The full query is always retained, while common
/// Siri command words are removed from supplemental terms.
nonisolated enum ShelvIntentSearchVocabulary {
    private static let stopWords: Set<String> = [
        // English
        "a", "all", "an", "and", "album", "albums", "artist", "artists", "by",
        "for", "from", "in", "library", "me", "music", "my", "of", "on", "play", "please",
        "radio", "shelv", "shuffle", "shuffled", "song", "songs", "station", "the", "track",
        "tracks", "using", "with", "instant", "mix",
        // German
        "alle", "album", "alben", "auf", "aus", "bitte", "das", "dem", "den", "der",
        "die", "eine", "einem", "einen", "einer", "für", "gemischt", "in", "künstler", "lied",
        "lieder", "mediathek", "meine", "meinem", "meinen", "meiner", "mit", "musik",
        "instant", "mix", "radio", "sender", "shelv", "shuffle", "spiele", "spielen", "spiel",
        "titel", "von",
        // Simplified Chinese. AudioSearch normally extracts the catalog query,
        // but these keep explicit shortcut searches deterministic as well.
        "播放", "请", "在", "中", "用", "随机", "随机播放", "即时", "混音"
    ]

    private static let kindWords: [(ShortcutPlayableKind, Set<String>)] = [
        (.radio, ["radio", "station", "sender", "radiosender", "电台"]),
        (.playlist, ["playlist", "playlists", "wiedergabeliste", "播放列表"]),
        (.album, ["album", "alben", "专辑"]),
        (.artist, ["artist", "artists", "künstler", "interpret", "interpreten", "艺人", "歌手"]),
        (.song, ["song", "songs", "track", "tracks", "titel", "lied", "lieder", "歌曲", "单曲"]),
    ]

    /// These words are useful media-kind hints on their own, but repeated uses
    /// commonly belong to a title rather than to the request grammar.
    private static let ambiguousRepeatedKindMarkers: Set<String> = ["station"]

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

    static func explicitKind(in rawQuery: String) -> ShortcutPlayableKind? {
        let queryTokens = kindDetectionTokens(in: rawQuery)
        let artistRequestPhrases = [
            "music by", "songs by", "tracks by",
            "musik von", "lieder von", "titel von",
        ]
        if artistRequestPhrases.contains(where: {
            !tokenSequencePositions(kindDetectionTokens(in: $0), in: queryTokens).isEmpty
        }) {
            return .artist
        }
        return kindWords.compactMap { kind, markers -> (ShortcutPlayableKind, Int)? in
            let positions = markers.compactMap { marker -> Int? in
                markerPosition(marker, in: queryTokens)
            }
            guard let position = positions.min() else { return nil }
            return (kind, position)
        }
        .min {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.rawValue < $1.0.rawValue
        }?.0
    }

    static func containsKindMarker(_ kind: ShortcutPlayableKind, in rawQuery: String) -> Bool {
        guard let markers = kindWords.first(where: { $0.0 == kind })?.1 else { return false }
        let queryTokens = kindDetectionTokens(in: rawQuery)
        return markers.contains { markerPosition($0, in: queryTokens) != nil }
    }

    static func containsTokenSequence(_ phrase: String, in rawQuery: String) -> Bool {
        let queryTokens = kindDetectionTokens(in: rawQuery)
        let phraseTokens = kindDetectionTokens(in: phrase)
        return !tokenSequencePositions(phraseTokens, in: queryTokens).isEmpty
    }

    static func allows(
        _ kind: ShortcutPlayableKind,
        for rawQuery: String,
        requiresExplicitRadio: Bool
    ) -> Bool {
        if let explicitKind = explicitKind(in: rawQuery) {
            return kind == explicitKind
        }
        return !requiresExplicitRadio || kind != .radio
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

    /// Tokenizes alphabetic languages by word and Han text by scalar so that
    /// exact marker sequences also work for languages that do not use spaces.
    private static func kindDetectionTokens(in value: String) -> [String] {
        let folded = normalizedKey(value)
        var result: [String] = []
        var currentWord = ""

        func flushCurrentWord() {
            guard !currentWord.isEmpty else { return }
            result.append(currentWord)
            currentWord.removeAll(keepingCapacity: true)
        }

        for scalar in folded.unicodeScalars {
            if isHanIdeograph(scalar) {
                flushCurrentWord()
                result.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                currentWord.unicodeScalars.append(scalar)
            } else {
                flushCurrentWord()
            }
        }
        flushCurrentWord()
        return result
    }

    private static func isHanIdeograph(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func markerPosition(_ marker: String, in queryTokens: [String]) -> Int? {
        let markerTokens = kindDetectionTokens(in: marker)
        let positions = tokenSequencePositions(markerTokens, in: queryTokens)
        guard !positions.isEmpty else { return nil }

        let markerKey = markerTokens.joined(separator: " ")
        if ambiguousRepeatedKindMarkers.contains(markerKey), positions.count > 1 {
            return nil
        }
        return positions[0]
    }

    private static func tokenSequencePositions(
        _ markerTokens: [String],
        in queryTokens: [String]
    ) -> [Int] {
        guard !markerTokens.isEmpty, markerTokens.count <= queryTokens.count else { return [] }
        let lastStart = queryTokens.count - markerTokens.count
        return (0...lastStart).filter { start in
            queryTokens[start..<(start + markerTokens.count)].elementsEqual(markerTokens)
        }
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = normalized(trimmed)
        guard !key.isEmpty, !values.contains(where: { normalized($0) == key }) else { return }
        values.append(trimmed)
    }
}

nonisolated enum ShelvIntentSearchRanking {
    static func score(
        kind: ShortcutPlayableKind,
        title: String,
        artistName: String?,
        albumTitle: String?,
        query: String
    ) -> Int {
        let normalizedQuery = ShelvIntentSearchVocabulary.normalized(query)
        var seenFields = Set<String>()
        let fields = [title, artistName, albumTitle]
            .compactMap { $0 }
            .map(ShelvIntentSearchVocabulary.normalized)
            .filter { !$0.isEmpty && seenFields.insert($0).inserted }
        let queryWords = Set(normalizedQuery.split(separator: " ").map(String.init))
        var score = 0

        for field in fields {
            if field == normalizedQuery { score += 120 }
            else if field.contains(normalizedQuery) { score += 60 }
            let words = Set(field.split(separator: " ").map(String.init))
            score += queryWords.intersection(words).count * 12
        }

        switch kind {
        case .song where ShelvIntentSearchVocabulary.containsKindMarker(.song, in: query):
            score += 35
        case .album where ShelvIntentSearchVocabulary.containsKindMarker(.album, in: query):
            score += 35
        case .artist where ShelvIntentSearchVocabulary.containsKindMarker(.artist, in: query)
            || containsAnyTokenSequence(
                query,
                ["music by", "songs by", "musik von", "lieder von"]
            ):
            score += 35
        case .playlist where ShelvIntentSearchVocabulary.containsKindMarker(.playlist, in: query):
            score += 35
        case .radio where ShelvIntentSearchVocabulary.containsKindMarker(.radio, in: query):
            score += 35
        default:
            break
        }
        return score
    }

    private static func containsAnyTokenSequence(_ value: String, _ phrases: [String]) -> Bool {
        phrases.contains { ShelvIntentSearchVocabulary.containsTokenSequence($0, in: value) }
    }
}
