import Foundation

nonisolated enum InstantMixService {
    static let targetCount = 50

    private static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "enableInstantMix") != nil else { return true }
        return defaults.bool(forKey: "enableInstantMix")
    }

    @MainActor
    static func playAlbumMix(for album: Album) {
        playAlbumMix(for: album, player: AudioPlayerService.shared)
    }

    @MainActor
    static func playAlbumMix(for album: Album, player: AudioPlayerService) {
        guard isEnabled else { return }
        Task {
            let songs = await albumMix(for: album)
            guard !songs.isEmpty else {
                NotificationCenter.default.post(name: .instantMixUnavailable, object: nil)
                return
            }
            player.play(songs: songs, startIndex: 0)
        }
    }

    @MainActor
    static func playArtistMix(for artist: Artist) {
        playArtistMix(for: artist, player: AudioPlayerService.shared)
    }

    @MainActor
    static func playArtistMix(for artist: Artist, player: AudioPlayerService) {
        guard isEnabled else { return }
        Task {
            let songs = await artistMix(for: artist)
            guard !songs.isEmpty else {
                NotificationCenter.default.post(name: .instantMixUnavailable, object: nil)
                return
            }
            player.play(songs: songs, startIndex: 0)
        }
    }

    static func albumMix(for album: Album) async -> [Song] {
        guard !UserDefaults.standard.bool(forKey: "offlineModeEnabled") else { return [] }

        let api = SubsonicAPIService.shared
        let detail = try? await api.getAlbum(id: album.id)
        let albumSongs = detail?.song ?? album.songs ?? []
        let seedSong = albumSongs.randomElement()

        if let seedSong {
            return await moreLikeThisQueue(for: seedSong)
        }

        let artistIds = unique([album.artistId, detail?.artistId])
        let artistName = album.artist ?? detail?.artist
        let genre = album.genre ?? detail?.genre
        var songs: [Song] = []
        var seen = Set<String>()

        for artistId in artistIds {
            push(try? await api.getSimilarSongs2(id: artistId, count: targetCount), into: &songs, seen: &seen)
            if songs.count >= targetCount { return songs }
        }

        if let genre {
            push(try? await api.getRandomSongs(size: targetCount * 2, genre: genre), into: &songs, seen: &seen)
            if songs.count >= targetCount { return songs }
        }

        if let artistName {
            push(try? await api.getTopSongs(artistName: artistName, count: targetCount), into: &songs, seen: &seen)
        }

        return songs
    }

    static func artistMix(for artist: Artist) async -> [Song] {
        guard !UserDefaults.standard.bool(forKey: "offlineModeEnabled") else { return [] }
        var seen: Set<String> = []
        var songs: [Song] = []

        push(try? await SubsonicAPIService.shared.getSimilarSongs2(id: artist.id, count: targetCount),
             into: &songs,
             seen: &seen)
        return songs
    }

    private static func moreLikeThisQueue(for source: Song) async -> [Song] {
        let api = SubsonicAPIService.shared
        var seen = Set([source.id])
        var songs: [Song] = []

        push(try? await api.getSimilarSongs(id: source.id, count: targetCount), into: &songs, seen: &seen)
        if songs.count >= targetCount { return songs }

        if let artistId = source.artistId {
            push(try? await api.getSimilarSongs2(id: artistId, count: targetCount), into: &songs, seen: &seen)
            if songs.count >= targetCount { return songs }
        }

        if let genre = source.genre {
            push(try? await api.getRandomSongs(size: targetCount * 2, genre: genre), into: &songs, seen: &seen)
            if songs.count >= targetCount { return songs }
        }

        if let artistName = source.artist {
            push(try? await api.getTopSongs(artistName: artistName, count: targetCount), into: &songs, seen: &seen)
        }

        return songs
    }

    private static func unique(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func push(_ incoming: [Song]?, into songs: inout [Song], seen: inout Set<String>) {
        guard let incoming else { return }
        for song in incoming {
            guard songs.count < targetCount else { return }
            guard seen.insert(song.id).inserted else { continue }
            songs.append(song)
        }
    }
}
