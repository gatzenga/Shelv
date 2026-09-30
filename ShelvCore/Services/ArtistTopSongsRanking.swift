import Foundation

/// The ordering rules behind the top-songs section of the artist pages,
/// kept free of any network call so they can be tested on their own.
nonisolated enum ArtistTopSongsRanking {
    /// Songs kept for the section.
    static let limit = 10

    /// Albums scanned by the play-count ranking, most played first. Artists
    /// with a deep back catalogue would otherwise fan out one album request
    /// per release just to fill a short list.
    static let fallbackAlbumLimit = 25

    /// Albums scanned when matching Last.fm's popular tracks. A hit can sit on
    /// an album that was never played, so the play count says little here and
    /// the cap only guards against very large catalogues.
    static let lastFMAlbumLimit = 40

    /// How many popular tracks Last.fm is asked for. Only the ones that exist
    /// in the library are shown, so it asks wide and keeps `limit`.
    static let lastFMTrackCount = 100

    /// The albums worth scanning for play counts, most played first so the cap
    /// keeps the tracks that can actually reach the top.
    static func fallbackAlbums(from albums: [Album]) -> [Album] {
        Array(
            albums
                .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
                .prefix(fallbackAlbumLimit)
        )
    }

    static func lastFMAlbums(from albums: [Album]) -> [Album] {
        Array(
            albums
                .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
                .prefix(lastFMAlbumLimit)
        )
    }

    /// Ranking from the play counts reported by the server. Never-played tracks
    /// are dropped, an untouched library has no top songs and should show none.
    static func rankByPlayCount(_ songs: [Song], limit: Int = limit) -> [Song] {
        let played = songs.filter { ($0.playCount ?? 0) > 0 }
        guard !played.isEmpty else { return [] }
        let ordered = played.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        return Array(deduplicatedByTitle(ordered).prefix(limit))
    }

    /// Last.fm's popular tracks, in Last.fm's order, resolved to the artist's
    /// own songs. Tracks that are not in the library are skipped, and when a
    /// track exists as single and on an album the copy played most is used.
    static func rankLastFMTracks(
        _ tracks: [LastFMTrack],
        in songs: [Song],
        limit: Int = limit
    ) -> [Song] {
        var result: [Song] = []
        var seenTitles = Set<String>()
        for track in tracks {
            guard let song = LastFMTrackMatcher.bestMatch(for: track, in: songs),
                  seenTitles.insert(titleKey(song.title)).inserted
            else { continue }
            result.append(song)
            if result.count == limit { break }
        }
        return result
    }

    /// Keeps the first occurrence of every title. Libraries routinely hold the
    /// same track on an album, on a single and on a compilation, and a top list
    /// that repeats itself is worse than a shorter one.
    private static func deduplicatedByTitle(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert(titleKey($0.title)).inserted }
    }

    private static func titleKey(_ title: String) -> String {
        title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
