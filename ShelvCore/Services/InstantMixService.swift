import Foundation
import OSLog
#if compiler(>=6.4) && canImport(AppIntents) && canImport(MediaIntents) && !os(tvOS) && !os(watchOS)
import AppIntents
import MediaIntents
#endif

nonisolated enum InstantMixService {
    static let targetCount = 50
    private static let logger = Logger(subsystem: "ch.vkugler.Shelv", category: "InstantMix")
    private static let artistSeedLock = NSLock()
    nonisolated(unsafe) private static var lastArtistSeedIds: [String: String] = [:]

    private static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PersonalizationPreferenceKey.showInstantMixActions) != nil else { return true }
        return defaults.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions)
    }

    @MainActor
    static func playAlbumMix(for album: Album) {
        playAlbumMix(for: album, player: AudioPlayerService.shared)
    }

    @MainActor
    static func playAlbumMix(for album: Album, player: AudioPlayerService) {
        guard isEnabled else { return }
        let serverConfigID = SubsonicAPIService.shared.activeServer?.id.uuidString
        Task {
            let songs = await albumMix(for: album)
            guard !songs.isEmpty else {
                NotificationCenter.default.post(name: .instantMixUnavailable, object: nil)
                return
            }
            guard case .started = await player.playAndWait(songs: songs, startIndex: 0) else { return }
            await donateSuccessfulMix(
                kind: .album,
                contentID: album.id,
                title: album.name,
                serverConfigID: serverConfigID
            )
        }
    }

    @MainActor
    static func playArtistMix(for artist: Artist) {
        playArtistMix(for: artist, player: AudioPlayerService.shared)
    }

    @MainActor
    static func playArtistMix(for artist: Artist, player: AudioPlayerService) {
        guard isEnabled else { return }
        let serverConfigID = SubsonicAPIService.shared.activeServer?.id.uuidString
        Task {
            let songs = await artistMix(for: artist)
            guard !songs.isEmpty else {
                NotificationCenter.default.post(name: .instantMixUnavailable, object: nil)
                return
            }
            guard case .started = await player.playAndWait(songs: songs, startIndex: 0) else { return }
            await donateSuccessfulMix(
                kind: .artist,
                contentID: artist.id,
                title: artist.name,
                serverConfigID: serverConfigID
            )
        }
    }

    @MainActor
    static func playSongMix(for song: Song) {
        playSongMix(for: song, player: AudioPlayerService.shared)
    }

    @MainActor
    static func playSongMix(for song: Song, player: AudioPlayerService) {
        guard isEnabled else { return }
        let serverConfigID = SubsonicAPIService.shared.activeServer?.id.uuidString
        Task {
            let songs = await songMix(for: song)
            guard !songs.isEmpty else {
                NotificationCenter.default.post(name: .instantMixUnavailable, object: nil)
                return
            }
            guard case .started = await player.playAndWait(songs: songs, startIndex: 0) else { return }
            await donateSuccessfulMix(
                kind: .song,
                contentID: song.id,
                title: song.title,
                serverConfigID: serverConfigID
            )
        }
    }

    static func albumMix(for album: Album) async -> [Song] {
        guard !UserDefaults.standard.bool(forKey: "offlineModeEnabled") else { return [] }

        let api = SubsonicAPIService.shared
        let detail = await fetch(endpoint: "getAlbum") {
            try await api.getAlbum(id: album.id, retries: 1)
        }
        let albumSongs = detail?.song ?? album.songs ?? []
        let seedSong = albumSongs.randomElement()

        if let seedSong {
            return meaningfulMix(await moreLikeThisQueue(for: seedSong, startingWith: seedSong))
        }

        let artistIds = unique([album.artistId, detail?.artistId])
        let artistName = album.artist ?? detail?.artist
        let genre = album.genre ?? detail?.genre
        var songs: [Song] = []
        var seen = Set<String>()

        for artistId in artistIds {
            push(await fetch(endpoint: "getSimilarSongs2") {
                try await api.getSimilarSongs2(id: artistId, count: targetCount, retries: 1)
            }, into: &songs, seen: &seen)
            if songs.count >= targetCount { return songs }
        }

        if let genre {
            push(await fetch(endpoint: "getRandomSongs") {
                try await api.getRandomSongs(size: targetCount * 2, genre: genre, retries: 1)
            }, into: &songs, seen: &seen)
            if songs.count >= targetCount { return songs }
        }

        if let artistName {
            push(await fetch(endpoint: "getTopSongs") {
                try await api.getTopSongs(artistName: artistName, count: targetCount, retries: 1)
            }, into: &songs, seen: &seen)
        }

        return meaningfulMix(songs)
    }

    static func artistMix(for artist: Artist) async -> [Song] {
        guard !UserDefaults.standard.bool(forKey: "offlineModeEnabled") else { return [] }
        var seen: Set<String> = []
        var songs: [Song] = []
        let api = SubsonicAPIService.shared

        if let seedSong = await randomSeedSong(for: artist, api: api) {
            push([seedSong], into: &songs, seen: &seen)
        }

        push(await fetch(endpoint: "getSimilarSongs2") {
            try await api.getSimilarSongs2(id: artist.id, count: targetCount, retries: 1)
        },
             into: &songs,
             seen: &seen)
        return meaningfulMix(songs)
    }

    static func songMix(for song: Song) async -> [Song] {
        guard !UserDefaults.standard.bool(forKey: "offlineModeEnabled") else { return [] }
        return meaningfulMix(await moreLikeThisQueue(for: song, startingWith: song))
    }

    private static func moreLikeThisQueue(for source: Song, startingWith seed: Song?) async -> [Song] {
        let api = SubsonicAPIService.shared
        var seen: Set<String> = []
        var songs: [Song] = []

        if let seed {
            push([seed], into: &songs, seen: &seen)
        } else {
            seen.insert(source.id)
        }

        push(await fetch(endpoint: "getSimilarSongs") {
            try await api.getSimilarSongs(id: source.id, count: targetCount, retries: 1)
        }, into: &songs, seen: &seen)
        if songs.count >= targetCount { return songs }

        if let artistId = source.artistId {
            push(await fetch(endpoint: "getSimilarSongs2") {
                try await api.getSimilarSongs2(id: artistId, count: targetCount, retries: 1)
            }, into: &songs, seen: &seen)
            if songs.count >= targetCount { return songs }
        }

        if let genre = source.genre {
            push(await fetch(endpoint: "getRandomSongs") {
                try await api.getRandomSongs(size: targetCount * 2, genre: genre, retries: 1)
            }, into: &songs, seen: &seen)
            if songs.count >= targetCount { return songs }
        }

        if let artistName = source.artist {
            push(await fetch(endpoint: "getTopSongs") {
                try await api.getTopSongs(artistName: artistName, count: targetCount, retries: 1)
            }, into: &songs, seen: &seen)
        }

        return songs
    }

    private static func randomSeedSong(for artist: Artist, api: SubsonicAPIService) async -> Song? {
        let previousId = artistSeedLock.withLock { lastArtistSeedIds[artist.id] }
        let detail = await fetch(endpoint: "getArtist") {
            try await api.getArtist(id: artist.id, retries: 1)
        }

        if let albums = detail?.album, !albums.isEmpty {
            var repeatedFallback: Song?

            for album in albums.shuffled() {
                let albumDetail = await fetch(endpoint: "getAlbum") {
                    try await api.getAlbum(id: album.id, retries: 1)
                }
                guard let albumDetail else { continue }
                let candidates = InstantMixQueueBuilder.artistSeedCandidates(from: albumDetail.song ?? [], for: artist)
                if let seed = InstantMixQueueBuilder.randomSeed(from: candidates, avoiding: previousId) {
                    guard seed.id == previousId else {
                        rememberArtistSeed(seed.id, for: artist.id)
                        return seed
                    }
                    repeatedFallback = repeatedFallback ?? seed
                }
            }

            if let repeatedFallback {
                rememberArtistSeed(repeatedFallback.id, for: artist.id)
                return repeatedFallback
            }
        }

        let topSongs = await fetch(endpoint: "getTopSongs") {
            try await api.getTopSongs(artistName: artist.name, count: targetCount, retries: 1)
        } ?? []
        let candidates = InstantMixQueueBuilder.artistSeedCandidates(from: topSongs, for: artist)
        guard let seed = InstantMixQueueBuilder.randomSeed(from: candidates, avoiding: previousId) else { return nil }
        rememberArtistSeed(seed.id, for: artist.id)
        return seed
    }

    private static func rememberArtistSeed(_ songId: String, for artistId: String) {
        artistSeedLock.withLock {
            lastArtistSeedIds[artistId] = songId
        }
    }

    private static func unique(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func push(_ incoming: [Song]?, into songs: inout [Song], seen: inout Set<String>) {
        InstantMixQueueBuilder.append(incoming, into: &songs, seen: &seen, limit: targetCount)
    }

    private static func meaningfulMix(_ songs: [Song]) -> [Song] {
        guard songs.count > 1 else {
            logger.notice("Instant Mix unavailable relatedTrackCount=\(max(0, songs.count - 1), privacy: .public)")
            return []
        }
        return songs
    }

    /// UI entry points call this only after AVFoundation confirms playback.
    /// System intents use the non-playing mix builders and are donated by the
    /// system automatically, so Siri interactions never create duplicate data.
    private static func donateSuccessfulMix(
        kind: ShortcutPlayableKind,
        contentID: String,
        title: String,
        serverConfigID: String?
    ) async {
        #if compiler(>=6.4) && canImport(AppIntents) && canImport(MediaIntents) && !os(tvOS) && !os(watchOS)
        guard #available(iOS 27.0, macOS 27.0, *),
              let serverConfigID,
              [.song, .album, .artist].contains(kind)
        else { return }
        let reference = ShortcutPlayableReference(
            serverConfigID: serverConfigID,
            kind: kind,
            contentID: contentID
        )
        let station = ShelvAudioAlgorithmicStationEntity(reference: reference, title: title)
        do {
            let intent = ShelvPlayAudioIntent()
            intent.audioEntity = .algorithmicStation(station)
            intent.playbackAttributes = []
            intent.warmupAudioQueueResult = nil
            intent.queueLocation = nil
            try await intent.donate()
        } catch {
            logger.error(
                "Instant Mix donation failed kind=\(kind.rawValue, privacy: .public) error=\(String(describing: error), privacy: .private(mask: .hash))"
            )
        }
        #endif
    }

    private static func fetch<Value: Sendable>(
        endpoint: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        guard !Task.isCancelled else { return nil }
        do {
            return try await operation()
        } catch {
            guard !Task.isCancelled,
                  ShortcutPlaybackError.remoteFailure(error) != .cancelled
            else { return nil }
            logger.error(
                "Instant Mix endpoint failed endpoint=\(endpoint, privacy: .public) error=\(String(describing: error), privacy: .private(mask: .hash))"
            )
            return nil
        }
    }
}
