import Foundation

nonisolated enum InstantMixQueueBuilder {
    static func artistSeedCandidates(from songs: [Song], for artist: Artist) -> [Song] {
        songs.filter { song in
            if let songArtistId = song.artistId {
                return songArtistId == artist.id
            }
            guard let songArtist = song.artist else { return false }
            return normalizedArtistName(songArtist) == normalizedArtistName(artist.name)
        }
    }

    static func randomSeed(from candidates: [Song], avoiding previousId: String?) -> Song? {
        guard !candidates.isEmpty else { return nil }
        let pool: [Song]
        if candidates.count > 1, let previousId {
            let filtered = candidates.filter { $0.id != previousId }
            pool = filtered.isEmpty ? candidates : filtered
        } else {
            pool = candidates
        }
        return pool.randomElement()
    }

    static func mixQueue(startingWith seed: Song, followedBy relatedSongs: [Song], limit: Int = 50) -> [Song] {
        var seen: Set<String> = []
        var songs: [Song] = []
        append([seed], into: &songs, seen: &seen, limit: limit)
        append(relatedSongs, into: &songs, seen: &seen, limit: limit)
        return songs
    }

    static func append(_ incoming: [Song]?, into songs: inout [Song], seen: inout Set<String>, limit: Int) {
        guard let incoming else { return }
        for song in incoming {
            guard songs.count < limit else { return }
            guard seen.insert(song.id).inserted else { continue }
            songs.append(song)
        }
    }

    private static func normalizedArtistName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
