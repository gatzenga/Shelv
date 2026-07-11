import Foundation

/// Normalizes natural-language media requests into a small, deterministic set
/// of Navidrome search terms. The full query is always retained, while common
/// Siri command words are removed from supplemental terms.
nonisolated enum ShelvIntentSearchVocabulary {
    private static let stopWords: Set<String> = [
        // English
        "a", "all", "an", "and", "ask", "album", "albums", "artist", "artists", "by",
        "called", "can", "could",
        "for", "from", "in", "library", "me", "music", "my", "of", "on", "play", "please",
        "radio", "shelv", "shuffle", "shuffled", "song", "songs", "station", "the", "track",
        "tracks", "using", "with", "instant", "mix", "named", "siri", "some", "something",
        "start", "titled", "you", "ask shelv to play", "ask shelv to shuffle",
        // German
        "alle", "album", "alben", "auf", "aus", "bitte", "das", "dem", "den", "der",
        "die", "eine", "einem", "einen", "einer", "für", "gemischt", "in", "künstler", "lied",
        "lieder", "mediathek", "meine", "meinem", "meinen", "meiner", "mit", "musik",
        "instant", "mix", "radio", "sender", "shelv", "shuffle", "spiele", "spielen", "spiel",
        "titel", "von", "genannt", "namens", "siri", "starte",
        // Simplified Chinese. AudioSearch normally extracts the catalog query,
        // but these keep explicit shortcut searches deterministic as well.
        "播放", "请", "在", "中", "用", "的", "音乐", "随机", "随机播放", "即时", "混音"
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

    /// Returns only the catalog-bearing parts of a spoken request. Phrase-wise
    /// removal is important for Han text and avoids substring mistakes such as
    /// treating "Radiohead" as the media-kind word "radio".
    static func contentTokens(in rawQuery: String) -> [String] {
        var tokens = kindDetectionTokens(in: rawQuery)
        let grammar = stopWords.union(kindWords.flatMap { $0.1 })
            .map(kindDetectionTokens)
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.joined(separator: " ") < rhs.joined(separator: " ")
            }

        for phrase in grammar {
            tokens = removingAllOccurrences(of: phrase, from: tokens)
        }
        return tokens
    }

    static func normalizedTokens(in value: String) -> [String] {
        kindDetectionTokens(in: value)
    }

    /// Extracts the likely catalog name while preserving words that may be
    /// part of a real title (for example "All My Loving" or "The Beatles").
    /// Unlike `contentTokens`, this removes only command wrappers and one
    /// explicit media-kind marker instead of treating every grammar word as a
    /// stop word.
    static func primaryRequestTokens(in rawQuery: String) -> [String] {
        var tokens = kindDetectionTokens(in: rawQuery)
        let leadingPhrases = [
            "ask shelv to play", "ask shelv to shuffle",
            "play an instant mix for", "play instant mix for",
            "create an instant mix from", "create instant mix from",
            "spiele einen instant mix für", "spiele instant mix für",
            "erstelle einen instant mix aus", "erstelle einen instant mix von",
            "starte einen instant mix für",
            "can you play", "could you play", "please play", "please shuffle",
            "play me", "shuffle me", "start playing", "hey siri",
            "spiele mir", "bitte spiele", "bitte spiel", "hey siri",
            "在 shelv 中播放", "在 shelv 中随机播放",
            "play", "shuffle", "start", "ask", "spiele", "spielen", "spiel", "starte",
            "播放", "随机播放", "请",
        ].map { kindDetectionTokens(in: $0) }.sorted { $0.count > $1.count }
        let trailingPhrases = [
            "in shelv", "with shelv", "using shelv", "on shelv",
            "mit shelv", "auf shelv", "in shelv",
        ].map { kindDetectionTokens(in: $0) }.sorted { $0.count > $1.count }

        var removedWrapper = true
        while removedWrapper {
            removedWrapper = false
            for phrase in leadingPhrases where tokens.starts(with: phrase) {
                tokens.removeFirst(phrase.count)
                removedWrapper = true
                break
            }
        }
        removedWrapper = true
        while removedWrapper {
            removedWrapper = false
            for phrase in trailingPhrases where tokens.count >= phrase.count
                && tokens.suffix(phrase.count).elementsEqual(phrase) {
                tokens.removeLast(phrase.count)
                removedWrapper = true
                break
            }
        }

        let leadingFillers = Set(["please", "me", "some", "something", "bitte", "mir"])
        while let first = tokens.first, leadingFillers.contains(first) {
            tokens.removeFirst()
        }

        if let explicitKind = explicitKind(in: rawQuery),
           let markers = kindWords.first(where: { $0.0 == explicitKind })?.1 {
            let match = markers.compactMap { marker -> (position: Int, length: Int)? in
                let markerTokens = kindDetectionTokens(in: marker)
                guard let position = tokenSequencePositions(markerTokens, in: tokens).first else {
                    return nil
                }
                return (position, markerTokens.count)
            }.min { $0.position < $1.position }

            if let match {
                let determiners = Set([
                    "a", "an", "the", "das", "dem", "den", "der", "die",
                    "ein", "eine", "einem", "einen", "einer"
                ])
                let markerStart = match.position
                var contentStart = markerStart
                tokens.removeSubrange(markerStart..<(markerStart + match.length))
                if markerStart > tokens.startIndex,
                   determiners.contains(tokens[tokens.index(before: markerStart)]) {
                    tokens.remove(at: tokens.index(before: markerStart))
                    contentStart -= 1
                }
                let nameMarkers = Set(["called", "named", "titled", "genannt", "namens"])
                if contentStart < tokens.endIndex, nameMarkers.contains(tokens[contentStart]) {
                    tokens.remove(at: contentStart)
                }
            }
        }

        // "Imagine Dragons music" uses music as a request noun, while a
        // one-word item actually named "Music" must remain searchable.
        if let last = tokens.last,
           tokens.count > 1,
           ["music", "musik", "音乐"].contains(last) {
            tokens.removeLast()
        }
        return tokens
    }

    static func explicitKind(in rawQuery: String) -> ShortcutPlayableKind? {
        let queryTokens = kindDetectionTokens(in: rawQuery)
        let candidates = kindWords.compactMap { kind, markers -> (ShortcutPlayableKind, Int)? in
            let positions = markers.compactMap { marker -> Int? in
                markerPosition(marker, in: queryTokens)
            }
            guard let position = positions.min() else { return nil }
            return (kind, position)
        }

        // In "Time from the album Running on Empty" and "Demons by the
        // artist Imagine Dragons", media-kind words after the separator
        // describe the qualifier, not the object Siri asked us to play.
        let qualifierSeparators = Set(["by", "from", "von", "aus"])
        let qualifierBoundary = queryTokens.indices.first {
            qualifierSeparators.contains(queryTokens[$0])
        }
        let primaryCandidates = candidates.filter { candidate in
            guard let qualifierBoundary else { return true }
            return candidate.1 < qualifierBoundary
        }

        // Plural requests such as "songs by Imagine Dragons" mean the artist,
        // while "the song Demons by Imagine Dragons" still means one song.
        let artistSeparators = Set(["by", "von"])
        let artistRequestNouns = Set([
            "music", "songs", "tracks", "musik", "lieder", "titel"
        ])
        let commandGrammar = Set([
            "a", "all", "alle", "an", "ask", "bitte", "can", "could", "das", "dem", "den",
            "der", "die", "ein", "eine", "einem", "einen", "einer", "me", "mein", "meine",
            "meinem", "meinen", "meiner", "mir", "mische", "mischen", "my", "play", "please",
            "shelv", "shuffle", "shuffled", "some", "spiele", "spielen", "spiel", "start",
            "starte", "the", "to", "you"
        ])
        for separatorIndex in queryTokens.indices
        where artistSeparators.contains(queryTokens[separatorIndex]) {
            let requestNouns = queryTokens[..<separatorIndex].filter {
                !commandGrammar.contains($0)
            }
            let hasExplicitNonSongKind = primaryCandidates.contains {
                $0.1 < separatorIndex && $0.0 != .song
            }
            if !requestNouns.isEmpty,
               requestNouns.allSatisfy(artistRequestNouns.contains),
               !hasExplicitNonSongKind {
                return .artist
            }
        }

        return primaryCandidates.min {
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

    /// Narrows the work before any server request starts. Explicit requests
    /// such as "Pop Radio" only need the radio catalog, while an unqualified
    /// name such as "Mercury" deliberately keeps all plausible non-radio
    /// kinds so Siri can resolve an album, song, artist, or playlist.
    static func effectiveAllowedKinds(
        _ allowedKinds: Set<ShortcutPlayableKind>,
        for rawQuery: String,
        requiresExplicitRadio: Bool
    ) -> Set<ShortcutPlayableKind> {
        if let explicitKind = explicitKind(in: rawQuery) {
            return allowedKinds.contains(explicitKind) ? [explicitKind] : []
        }
        guard requiresExplicitRadio else { return allowedKinds }
        return allowedKinds.subtracting([.radio])
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

    private static func removingAllOccurrences(
        of phrase: [String],
        from tokens: [String]
    ) -> [String] {
        guard !phrase.isEmpty, phrase.count <= tokens.count else { return tokens }
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let remaining = tokens.count - index
            if remaining >= phrase.count,
               tokens[index..<(index + phrase.count)].elementsEqual(phrase) {
                index += phrase.count
            } else {
                result.append(tokens[index])
                index += 1
            }
        }
        return result
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = normalized(trimmed)
        guard !key.isEmpty, !values.contains(where: { normalized($0) == key }) else { return }
        values.append(trimmed)
    }
}

/// Resolves the named mixes that Siri may send through the native AudioSearch
/// path instead of through Shelv's dedicated App Shortcut. Keeping this
/// vocabulary separate from catalog search prevents words such as "Newest"
/// from being treated only as song or album titles.
nonisolated enum ShelvSmartMixIntentVocabulary {
    private static let strongAliases: [(ShortcutSmartMix, [String])] = [
        (
            .newest,
            [
                "newest tracks", "newest songs", "latest tracks", "latest songs",
                "latest music", "new music",
                "neueste titel", "neueste lieder", "neueste musik", "neue musik",
                "最新曲目", "最新歌曲", "最新音乐",
            ]
        ),
        (
            .frequent,
            [
                "frequently played", "most played", "top tracks", "top songs",
                "häufig gespielt", "häufig gespielte titel", "häufig gespielte lieder",
                "meist gespielt", "meistgespielte titel", "meistgespielte lieder",
                "经常播放", "最常播放",
            ]
        ),
        (
            .recent,
            [
                "recently played", "recent tracks", "recent songs", "recent music",
                "kürzlich gespielt", "kürzlich gespielte titel", "kürzlich gespielte lieder",
                "zuletzt gespielt", "zuletzt gespielte titel", "zuletzt gespielte lieder",
                "zuletzt gehörte titel",
                "最近播放", "最近曲目", "最近歌曲",
            ]
        ),
        (
            .shuffleAll,
            [
                "shuffle all", "shuffle all tracks", "shuffle all songs",
                "shuffle my library", "all tracks", "all songs", "random music",
                "alles mischen", "alle titel", "alle lieder", "meine mediathek mischen",
                "随机播放全部", "随机播放所有歌曲",
            ]
        ),
    ]

    private static let weakAliases: [(ShortcutSmartMix, Set<String>)] = [
        (.newest, ["newest", "latest", "neueste", "neuste", "最新"]),
        (.frequent, ["frequent", "häufig", "经常播放"]),
        (.recent, ["recent", "kürzlich", "最近"]),
    ]

    private static let explicitNameMarkers = [
        "named", "called", "titled", "namens", "mit dem titel", "名为", "叫做",
    ]

    static func smartMix(for rawQuery: String) -> ShortcutSmartMix? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        // A request such as "play the album named Newest" is explicitly about
        // catalog content, even though its title matches a mix name.
        guard !explicitNameMarkers.contains(where: {
            ShelvIntentSearchVocabulary.containsTokenSequence($0, in: query)
        }) else { return nil }

        let explicitKind = ShelvIntentSearchVocabulary.explicitKind(in: query)
        if let explicitKind, explicitKind != .song {
            return nil
        }

        // Multi-word aliases are strong enough to override the generic
        // song/track kind marker ("newest tracks" is a mix, not a title).
        for (mix, aliases) in strongAliases where aliases.contains(where: {
            ShelvIntentSearchVocabulary.containsTokenSequence($0, in: query)
        }) {
            return mix
        }

        // A single-word mix name is accepted only when the person didn't
        // explicitly request a song, album, artist, playlist, or station.
        guard explicitKind == nil else { return nil }
        var candidates = [ShelvIntentSearchVocabulary.normalized(query)]
        candidates += ShelvIntentSearchVocabulary.searchTerms(for: query)
            .dropFirst()
            .map(ShelvIntentSearchVocabulary.normalized)

        for (mix, aliases) in weakAliases where candidates.contains(where: aliases.contains) {
            return mix
        }
        return nil
    }
}

/// Maps download requests onto the special download queues exposed by Shelv.
/// Plain "downloads" keeps the existing shortcut behavior and shuffles, while
/// explicit all/newest wording selects the matching deterministic mode.
nonisolated enum ShelvDownloadsIntentVocabulary {
    private static let explicitNameMarkers = [
        "named", "called", "titled", "namens", "mit dem titel", "名为", "叫做",
    ]

    private static let downloadedDescriptors = Set([
        "downloaded", "heruntergeladen", "heruntergeladene", "heruntergeladenen",
        "下载", "已下载",
    ])

    static func mode(for rawQuery: String) -> ShortcutDownloadsMode? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        guard !explicitNameMarkers.contains(where: {
            ShelvIntentSearchVocabulary.containsTokenSequence($0, in: query)
        }) else { return nil }

        let tokens = ShelvIntentSearchVocabulary.normalizedTokens(in: query)
        let hasDownloadedDescriptor = tokens.contains(where: downloadedDescriptors.contains)
        let hasDownloadsNoun = tokens.contains("download")
            || tokens.contains("downloads")
            || ShelvIntentSearchVocabulary.containsTokenSequence("下载", in: query)
        guard hasDownloadedDescriptor || hasDownloadsNoun else { return nil }

        // An explicit catalog kind such as "the playlist Downloads" must stay
        // a catalog request. "Downloaded songs" remains a download request.
        if ShelvIntentSearchVocabulary.explicitKind(in: query) != nil,
           !hasDownloadedDescriptor {
            return nil
        }

        let newestAliases = [
            "newest downloads", "latest downloads", "newly downloaded",
            "neueste downloads", "zuletzt heruntergeladen", "最新下载",
        ]
        if newestAliases.contains(where: {
            ShelvIntentSearchVocabulary.containsTokenSequence($0, in: query)
        }) {
            return .newest
        }

        let allAliases = [
            "all downloads", "all downloaded music", "all downloaded tracks",
            "alle downloads", "alle heruntergeladenen titel", "所有下载", "全部下载",
        ]
        if allAliases.contains(where: {
            ShelvIntentSearchVocabulary.containsTokenSequence($0, in: query)
        }) {
            return .all
        }

        return .shuffled
    }
}

/// Recognizes a seeded Instant Mix request before Siri treats "mix" as the
/// name of a playlist. The returned string contains only the seed catalog name.
nonisolated enum ShelvInstantMixIntentVocabulary {
    private static let requestMarkers = [
        "instant mix for", "instant mix from", "instant mix of",
        "instant mix für", "instant mix aus", "instant mix von",
        "即时混音", "即时混合",
    ]

    static func seedQuery(from rawQuery: String) -> String? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              requestMarkers.contains(where: {
                  ShelvIntentSearchVocabulary.containsTokenSequence($0, in: query)
              })
        else { return nil }

        var tokens = ShelvIntentSearchVocabulary.primaryRequestTokens(in: query)
        while let first = tokens.first, ["instant", "mix"].contains(first) {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: " ")
    }
}

nonisolated enum ShelvIntentSearchRanking {
    private enum QualifierField {
        case artist
        case album
    }

    private struct QualifiedRequest {
        let titleTokens: [String]
        let qualifierTokens: [String]
        let field: QualifierField
    }

    static func score(
        kind: ShortcutPlayableKind,
        title: String,
        artistName: String?,
        albumTitle: String?,
        query: String
    ) -> Int {
        relevantScore(
            kind: kind,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            query: query
        ) ?? 0
    }

    /// Reduces playback candidates to one result when the request has one
    /// objectively best match. Genuine title ties remain available for Siri's
    /// own disambiguation instead of silently selecting the wrong media item.
    static func deterministicPlaybackMatches<Element>(
        _ items: [Element],
        query: String,
        ambiguityLimit: Int = 5,
        fields: (Element) -> (
            kind: ShortcutPlayableKind,
            title: String,
            artistName: String?,
            albumTitle: String?
        )
    ) -> [Element] {
        guard !items.isEmpty, ambiguityLimit > 0 else { return [] }

        let ranked = items.enumerated().compactMap {
            index,
            item -> (score: Int, index: Int, item: Element, title: String)? in
            let candidate = fields(item)
            guard let score = relevantScore(
                kind: candidate.kind,
                title: candidate.title,
                artistName: candidate.artistName,
                albumTitle: candidate.albumTitle,
                query: query
            ) else { return nil }
            return (score, index, item, candidate.title)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.index < $1.index
        }
        guard let best = ranked.first else { return [] }

        let requestName = ShelvIntentSearchVocabulary.primaryRequestTokens(in: query)
            .joined(separator: " ")
        if !requestName.isEmpty {
            let normalizedRequestName = ShelvIntentSearchVocabulary.normalized(requestName)
            let exactTitleMatches = ranked.filter {
                ShelvIntentSearchVocabulary.normalized($0.title) == normalizedRequestName
            }
            if exactTitleMatches.count == 1 {
                return [exactTitleMatches[0].item]
            }
            if exactTitleMatches.count > 1 {
                return exactTitleMatches.prefix(ambiguityLimit).map(\.item)
            }
        }

        if ranked.count == 1 { return [best.item] }
        let qualifierWords = Set(["by", "from", "von", "aus"])
        let hasQualifier = ShelvIntentSearchVocabulary.normalizedTokens(in: query)
            .contains(where: qualifierWords.contains)
        let hasExplicitKind = ShelvIntentSearchVocabulary.explicitKind(in: query) != nil
        if (hasQualifier || hasExplicitKind), best.score > ranked[1].score {
            return [best.item]
        }

        return ranked.prefix(ambiguityLimit).map(\.item)
    }

    /// Returns `nil` for a server result that doesn't actually satisfy the
    /// request. Navidrome search is intentionally broad; this boundary keeps a
    /// same-kind but unrelated result from ever reaching Siri.
    static func relevantScore(
        kind: ShortcutPlayableKind,
        title: String,
        artistName: String?,
        albumTitle: String?,
        query: String
    ) -> Int? {
        let primary = ShelvIntentSearchVocabulary.normalized(title)
        let artist = artistName.map(ShelvIntentSearchVocabulary.normalized) ?? ""
        let album = albumTitle.map(ShelvIntentSearchVocabulary.normalized) ?? ""
        guard !primary.isEmpty else { return nil }

        let explicitKind = ShelvIntentSearchVocabulary.explicitKind(in: query)
        if let explicitKind, explicitKind != kind { return nil }

        let primaryRequestTokens = ShelvIntentSearchVocabulary.primaryRequestTokens(in: query)
        let contentTokens = primaryRequestTokens.isEmpty
            ? ShelvIntentSearchVocabulary.contentTokens(in: query)
            : primaryRequestTokens
        let qualified = containsAll(primaryRequestTokens, in: primary)
            ? nil
            : qualifiedRequest(in: query)

        if let qualified {
            guard matchesQualifiedRequest(
                qualified,
                kind: kind,
                primary: primary,
                artist: artist,
                album: album,
                explicitKind: explicitKind
            ) else { return nil }
        } else {
            guard !contentTokens.isEmpty else { return nil }
            let target = explicitKind == nil
                ? [primary, artist, album].filter { !$0.isEmpty }.joined(separator: " ")
                : primary
            guard containsAll(contentTokens, in: target) else { return nil }
        }

        var result = fieldScore(primary, tokens: contentTokens, exact: 300, contains: 180, token: 30)
        if artist != primary {
            result += fieldScore(artist, tokens: contentTokens, exact: 140, contains: 80, token: 16)
        }
        if album != primary, album != artist {
            result += fieldScore(album, tokens: contentTokens, exact: 120, contains: 70, token: 14)
        }

        if let qualified {
            result += fieldScore(
                primary,
                tokens: qualified.titleTokens,
                exact: 260,
                contains: 150,
                token: 24
            )
            let qualifierField = qualified.field == .album ? album : artist
            result += fieldScore(
                qualifierField,
                tokens: qualified.qualifierTokens,
                exact: 180,
                contains: 110,
                token: 20
            )
        }
        if explicitKind == kind { result += 50 }
        return max(result, 1)
    }

    /// A primary match means the spoken catalog name resolves directly to this
    /// entity's own title/name, rather than only to a secondary artist or album
    /// field. Callers can prefer these matches to avoid offering Siri an artist
    /// plus every song by that artist for the same request.
    static func isPrimaryMatch(
        kind: ShortcutPlayableKind,
        title: String,
        artistName: String?,
        albumTitle: String?,
        query: String
    ) -> Bool {
        guard relevantScore(
            kind: kind,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            query: query
        ) != nil else { return false }

        let primaryRequestTokens = ShelvIntentSearchVocabulary.primaryRequestTokens(in: query)
        if !containsAll(primaryRequestTokens, in: ShelvIntentSearchVocabulary.normalized(title)),
           qualifiedRequest(in: query) != nil {
            return true
        }
        return containsAll(
            primaryRequestTokens.isEmpty
                ? ShelvIntentSearchVocabulary.contentTokens(in: query)
                : primaryRequestTokens,
            in: ShelvIntentSearchVocabulary.normalized(title)
        )
    }

    private static func qualifiedRequest(in query: String) -> QualifiedRequest? {
        let tokens = ShelvIntentSearchVocabulary.normalizedTokens(in: query)
        let separators = Set(["by", "from", "von", "aus"])
        let qualifyingNouns = Set([
            "music", "song", "songs", "track", "tracks", "titel", "lied", "lieder", "musik"
        ])
        let albumMarkers = Set(["album", "alben"])

        for index in tokens.indices.reversed() where separators.contains(tokens[index]) {
            var prefixTokens = ShelvIntentSearchVocabulary.primaryRequestTokens(
                in: tokens[..<index].joined(separator: " ")
            )
            let rawSuffix = Array(tokens[tokens.index(after: index)...])
            let suffixTokens = ShelvIntentSearchVocabulary.primaryRequestTokens(
                in: rawSuffix.joined(separator: " ")
            )
            guard !suffixTokens.isEmpty else { continue }

            let previousIsQualifyingNoun = index > tokens.startIndex
                && qualifyingNouns.contains(tokens[tokens.index(before: index)])
            if previousIsQualifyingNoun,
               !prefixTokens.isEmpty,
               prefixTokens.allSatisfy(qualifyingNouns.contains) {
                prefixTokens = []
            }
            guard !prefixTokens.isEmpty || previousIsQualifyingNoun else { continue }

            let field: QualifierField = rawSuffix.prefix(3).contains(where: albumMarkers.contains)
                ? .album
                : .artist
            return QualifiedRequest(
                titleTokens: prefixTokens,
                qualifierTokens: suffixTokens,
                field: field
            )
        }
        return nil
    }

    private static func matchesQualifiedRequest(
        _ request: QualifiedRequest,
        kind: ShortcutPlayableKind,
        primary: String,
        artist: String,
        album: String,
        explicitKind: ShortcutPlayableKind?
    ) -> Bool {
        if request.titleTokens.isEmpty {
            if kind == .artist {
                return containsAll(request.qualifierTokens, in: primary)
            }
            guard explicitKind == .song || explicitKind == .album else { return false }
        } else {
            guard kind != .artist, containsAll(request.titleTokens, in: primary) else { return false }
        }

        let qualifierField = request.field == .album ? album : artist
        return containsAll(request.qualifierTokens, in: qualifierField)
    }

    private static func containsAll(_ requestedTokens: [String], in field: String) -> Bool {
        guard !requestedTokens.isEmpty, !field.isEmpty else { return false }
        let fieldTokens = Set(ShelvIntentSearchVocabulary.normalizedTokens(in: field))
        return Set(requestedTokens).isSubset(of: fieldTokens)
    }

    private static func fieldScore(
        _ field: String,
        tokens: [String],
        exact: Int,
        contains: Int,
        token tokenWeight: Int
    ) -> Int {
        guard !field.isEmpty, !tokens.isEmpty else { return 0 }
        let phrase = tokens.joined(separator: " ")
        let fieldTokens = Set(ShelvIntentSearchVocabulary.normalizedTokens(in: field))
        var result = Set(tokens).intersection(fieldTokens).count * tokenWeight
        if field == phrase {
            result += exact
        } else if field.contains(phrase) {
            result += contains
        }
        return result
    }
}
