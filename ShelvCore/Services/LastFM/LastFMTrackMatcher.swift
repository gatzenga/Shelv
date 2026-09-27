import Foundation

/// Finds the library song behind a Last.fm scrobble.
///
/// Last.fm only knows artist, title and (for recent tracks) album as they were
/// scrobbled, so matching works on those names. Artist and title have to agree;
/// the album only breaks ties, because compilations like a self-made "Singles"
/// album do not exist on Last.fm under that artist.
nonisolated enum LastFMTrackMatcher {
    /// Queries to try in order until one returns a match.
    static func searchQueries(for track: LastFMTrack) -> [String] {
        let title = strippedTitle(track.title)
        let artist = artistNames(track.artist).first ?? track.artist
        var queries = ["\(artist) \(title)", title]
        if title != track.title { queries.append(track.title) }
        var seen = Set<String>()
        return queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The candidate that is the same recording, or `nil` if none qualifies.
    static func bestMatch(for track: LastFMTrack, in candidates: [Song]) -> Song? {
        let exactTitle = normalize(track.title)
        let looseTitle = normalize(strippedTitle(track.title))
        let wantedArtists = Set(artistNames(track.artist).map(normalize)).union([normalize(track.artist)])
        let wantedAlbum = track.album.map(normalize)

        var best: (song: Song, score: Int)?
        for song in candidates {
            let title = normalize(song.title)
            let titleScore: Int
            if title == exactTitle {
                titleScore = 2
            } else if normalize(strippedTitle(song.title)) == looseTitle, !looseTitle.isEmpty {
                titleScore = 1
            } else {
                continue
            }
            guard !songArtistNames(song).isDisjoint(with: wantedArtists) else { continue }

            var score = titleScore * 100
            if let wantedAlbum, let album = song.album, normalize(album) == wantedAlbum {
                score += 50
            }
            // Among equal matches, the version listened to most is the safest bet.
            score += min(song.playCount ?? 0, 49)
            if best == nil || score > best!.score {
                best = (song, score)
            }
        }
        return best?.song
    }

    /// Stable identity of a scrobbled track, used to drop repeats.
    static func key(for track: LastFMTrack) -> String {
        normalize(track.artist) + "\u{1F}" + normalize(track.title)
    }

    // MARK: - Normalisation

    /// Lowercased, without diacritics or punctuation, single spaced.
    static func normalize(_ value: String) -> String {
        let folded = value
            .replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Title without bracketed additions and version suffixes such as
    /// "(Remastered 2011)", "[Live]" or " - Radio Edit".
    static func strippedTitle(_ title: String) -> String {
        var result = title.replacingOccurrences(
            of: #"\s*[\(\[\{][^\)\]\}]*[\)\]\}]"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        if let dash = result.range(of: " - ", options: .backwards) {
            let suffix = result[dash.upperBound...].lowercased()
            let versionWords = [
                "remaster", "version", "edit", "mix", "live", "mono", "stereo", "demo",
                "acoustic", "single", "radio", "deluxe", "bonus", "instrumental", "feat",
            ]
            if versionWords.contains(where: { suffix.contains($0) }) {
                result = String(result[..<dash.lowerBound])
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    /// Splits collaborations like "A feat. B", "A & B" or "A, B" into names.
    static func artistNames(_ artist: String) -> [String] {
        artist
            .replacingOccurrences(
                of: #"\s*(,|;|&|/|•|·|×|\bfeat\.?|\bft\.?|\bfeaturing\b|\bvs\.?|\bx\b)\s*"#,
                with: "\u{1F}",
                options: [.regularExpression, .caseInsensitive]
            )
            .split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func songArtistNames(_ song: Song) -> Set<String> {
        var names: [String] = []
        names.append(contentsOf: [song.artist, song.displayArtist, song.displayAlbumArtist].compactMap { $0 })
        names.append(contentsOf: (song.artists ?? []).map(\.name))
        names.append(contentsOf: (song.albumArtists ?? []).map(\.name))
        var result = Set<String>()
        for name in names {
            result.insert(normalize(name))
            for part in artistNames(name) { result.insert(normalize(part)) }
        }
        result.remove("")
        return result
    }
}
