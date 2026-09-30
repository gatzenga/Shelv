import Foundation

/// Keeps the most played songs while albums are loaded one after another,
/// most played album first.
///
/// An album's play count is the sum of its songs' play counts, so no song can
/// have more plays than its album. Once the next album has no more plays than
/// the song in last place, none of its songs can displace anyone, and since the
/// albums are sorted, neither can any album after it. That is the point where
/// loading can stop without missing a song.
nonisolated struct FrequentSongsCollector {
    let limit: Int
    private(set) var top: [Song] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Plays an album has to beat to be worth loading: those of the song in
    /// last place once the list is full, zero before that.
    var cutoff: Int {
        guard top.count >= limit else { return 0 }
        return top.last?.playCount ?? 0
    }

    func isWorthLoading(albumPlayCount: Int?) -> Bool {
        (albumPlayCount ?? 0) > cutoff
    }

    /// Adds the songs of an album. Songs that were never played only pad the
    /// list and are left out.
    mutating func add(_ songs: [Song]) {
        let played = songs.filter { ($0.playCount ?? 0) > 0 }
        guard !played.isEmpty else { return }
        top = (top + played)
            .enumerated()
            .sorted {
                let lhs = $0.element.playCount ?? 0
                let rhs = $1.element.playCount ?? 0
                return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
            }
            .prefix(limit)
            .map(\.element)
    }
}
