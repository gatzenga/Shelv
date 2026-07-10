import Foundation

nonisolated enum ShortcutPlayableKind: String, CaseIterable, Hashable, Sendable {
    case song
    case album
    case artist
    case playlist
    case radio
}

nonisolated enum ShortcutPlaybackOrder: String, CaseIterable, Hashable, Sendable {
    case inOrder
    case shuffled
}

nonisolated enum ShortcutSmartMix: String, CaseIterable, Hashable, Sendable {
    case newest
    case frequent
    case recent
    case shuffleAll
}

nonisolated enum ShortcutDownloadsMode: String, CaseIterable, Hashable, Sendable {
    case all
    case shuffled
    case newest
}

nonisolated struct ShortcutPlayableReference: Hashable, Sendable {
    let serverConfigID: String
    let kind: ShortcutPlayableKind
    let contentID: String
}

nonisolated enum ShortcutPlaybackCommand: Hashable, Sendable {
    case playable(ShortcutPlayableReference, order: ShortcutPlaybackOrder)
    case mix(ShortcutSmartMix)
    case downloads(ShortcutDownloadsMode)
    case instantMix(ShortcutPlayableReference)
    case playPause
    case next
    case previous
}

nonisolated enum ShortcutPlaybackError: Error, Equatable, Sendable,
    CustomLocalizedStringResourceConvertible, LocalizedError {
    case noActiveServer
    case serverChanged
    case noNetwork
    case notFound
    case noPlayableContent
    case unavailableOffline
    case radioUnavailableOffline
    case playbackFailed
    case playbackTimedOut
    case cancelled

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noActiveServer: return "shortcut_error_no_server"
        case .serverChanged: return "shortcut_error_server_changed"
        case .noNetwork: return "shortcut_error_no_network"
        case .notFound: return "shortcut_error_not_found"
        case .noPlayableContent: return "shortcut_error_no_content"
        case .unavailableOffline: return "shortcut_error_unavailable_offline"
        case .radioUnavailableOffline: return "shortcut_error_radio_offline"
        case .playbackFailed: return "shortcut_error_playback_failed"
        case .playbackTimedOut: return "shortcut_error_playback_timed_out"
        case .cancelled: return "shortcut_error_cancelled"
        }
    }

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }
}

/// Single-flight command boundary for App Intents. All playback still goes
/// through the normal AudioPlayerService path, including Now Playing and
/// scrobbling.
@MainActor
final class ShortcutPlaybackCoordinator: @unchecked Sendable {
    static let shared = ShortcutPlaybackCoordinator()

    private struct Flight {
        let id: UInt64
        let command: ShortcutPlaybackCommand
        let task: Task<Result<Void, ShortcutPlaybackError>, Never>
    }

    private var nextFlightID: UInt64 = 0
    private var flight: Flight?

    private init() {}

    func execute(_ command: ShortcutPlaybackCommand) async throws {
        nextFlightID &+= 1
        let flightID = nextFlightID
        flight?.task.cancel()

        let playbackTask: Task<Result<Void, ShortcutPlaybackError>, Never> = Task { @MainActor [weak self] in
            guard let self else {
                return Result<Void, ShortcutPlaybackError>.failure(.cancelled)
            }
            do {
                try await self.runWithDeadline(command, flightID: flightID)
                return .success(())
            } catch let error as ShortcutPlaybackError {
                return .failure(error)
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch {
                return .failure(.playbackFailed)
            }
        }
        flight = Flight(id: flightID, command: command, task: playbackTask)

        let result = await withTaskCancellationHandler {
            await playbackTask.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelFlight(id: flightID)
            }
        }
        if flight?.id == flightID {
            flight = nil
        }
        if Task.isCancelled { throw ShortcutPlaybackError.cancelled }
        try unwrap(result)
    }

    private func cancelFlight(id: UInt64) {
        guard flight?.id == id else { return }
        flight?.task.cancel()
    }

    private func runWithDeadline(_ command: ShortcutPlaybackCommand, flightID: UInt64) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw ShortcutPlaybackError.cancelled }
                try await self.run(command, flightID: flightID)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(25))
                throw ShortcutPlaybackError.playbackTimedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func unwrap(_ result: Result<Void, ShortcutPlaybackError>) throws {
        switch result {
        case .success: return
        case .failure(let error): throw error
        }
    }

    private func run(_ command: ShortcutPlaybackCommand, flightID: UInt64) async throws {
        switch command {
        case .playable(let reference, let order):
            let server = try await prepareServer(expectedConfigID: reference.serverConfigID, flightID: flightID)
            try await play(reference, order: order, server: server, flightID: flightID)
        case .mix(let mix):
            let server = try await prepareServer(expectedConfigID: nil, flightID: flightID)
            try await play(mix, server: server, flightID: flightID)
        case .downloads(let mode):
            let server = try await prepareServer(expectedConfigID: nil, flightID: flightID)
            try await playDownloads(mode, server: server, flightID: flightID)
        case .instantMix(let reference):
            let server = try await prepareServer(expectedConfigID: reference.serverConfigID, flightID: flightID)
            try await playInstantMix(reference, server: server, flightID: flightID)
        case .playPause:
            try await performPlayPause()
        case .next:
            try await performSkip(next: true)
        case .previous:
            try await performSkip(next: false)
        }
    }

    private func prepareServer(expectedConfigID: String?, flightID: UInt64) async throws -> SubsonicServer {
        _ = ServerStore.shared
        guard let server = ServerStore.shared.activeServer else {
            throw ShortcutPlaybackError.noActiveServer
        }
        if let expectedConfigID, server.id.uuidString != expectedConfigID {
            throw ShortcutPlaybackError.serverChanged
        }

        await DownloadDatabase.shared.setup()
        await DownloadStore.shared.setActiveServer(storageServerID(for: server))
        await PlayLogService.shared.setup()
        try validateFlight(flightID, serverConfigID: server.id.uuidString)
        return server
    }

    private func validateFlight(_ flightID: UInt64, serverConfigID: String) throws {
        guard !Task.isCancelled else { throw ShortcutPlaybackError.cancelled }
        guard flight?.id == flightID else { throw ShortcutPlaybackError.cancelled }
        guard ServerStore.shared.activeServer?.id.uuidString == serverConfigID else {
            throw ShortcutPlaybackError.serverChanged
        }
    }

    private func requireNetwork() async throws {
        guard await NetworkStatus.shared.waitUntilNetworkAvailable() else {
            throw ShortcutPlaybackError.noNetwork
        }
    }

    private func shouldUseLocalPlayback() async -> Bool {
        if OfflineModeService.shared.isOffline { return true }
        return !(await NetworkStatus.shared.waitUntilNetworkAvailable())
    }

    private func play(
        _ reference: ShortcutPlayableReference,
        order: ShortcutPlaybackOrder,
        server: SubsonicServer,
        flightID: UInt64
    ) async throws {
        let serverConfigID = server.id.uuidString
        let downloaded = DownloadStore.shared
        let localOnly = await shouldUseLocalPlayback()

        switch reference.kind {
        case .song:
            let localSong = downloaded.songs.first { $0.songId == reference.contentID }?.asSong()
            let song: Song
            if localOnly {
                guard let localSong else { throw ShortcutPlaybackError.unavailableOffline }
                song = localSong
            } else {
                do {
                    song = try await SubsonicAPIService.shared.getSong(id: reference.contentID)
                } catch {
                    guard let localSong else { throw error }
                    song = localSong
                }
            }
            try validateFlight(flightID, serverConfigID: serverConfigID)
            try await requireStarted(AudioPlayerService.shared.playSongAndWait(song))

        case .album:
            let localSongs = downloaded.albums.first { $0.albumId == reference.contentID }?
                .songs.map { $0.asSong() } ?? []
            let songs: [Song]
            if localOnly {
                guard !localSongs.isEmpty else { throw ShortcutPlaybackError.unavailableOffline }
                songs = localSongs
            } else {
                do {
                    let remoteSongs = try await SubsonicAPIService.shared
                        .getAlbum(id: reference.contentID).song ?? []
                    songs = remoteSongs.isEmpty && !localSongs.isEmpty ? localSongs : remoteSongs
                } catch {
                    guard !localSongs.isEmpty else { throw error }
                    songs = localSongs
                }
            }
            try validateFlight(flightID, serverConfigID: serverConfigID)
            try await start(songs: songs, order: order)

        case .artist:
            let localSongs = downloaded.artists.first { $0.artistId == reference.contentID }?
                .albums.flatMap(\.songs).map { $0.asSong() } ?? []
            let songs: [Song]
            if localOnly {
                guard !localSongs.isEmpty else { throw ShortcutPlaybackError.unavailableOffline }
                songs = localSongs
            } else {
                do {
                    let detail = try await SubsonicAPIService.shared.getArtist(id: reference.contentID)
                    let remoteSongs = try await SubsonicAPIService.shared.getTopSongs(
                        artistName: detail.name,
                        count: 50
                    )
                    songs = remoteSongs.isEmpty && !localSongs.isEmpty ? localSongs : remoteSongs
                } catch {
                    guard !localSongs.isEmpty else { throw error }
                    songs = localSongs
                }
            }
            try validateFlight(flightID, serverConfigID: serverConfigID)
            try await start(songs: songs, order: order)

        case .playlist:
            let localSongs = await localPlaylistSongs(
                playlistID: reference.contentID,
                downloaded: downloaded
            )
            let songs: [Song]
            if localOnly {
                guard !localSongs.isEmpty else { throw ShortcutPlaybackError.unavailableOffline }
                songs = localSongs
            } else {
                if let playlist = await LibraryStore.shared.loadPlaylistDetail(id: reference.contentID),
                   let remoteSongs = playlist.songs,
                   !remoteSongs.isEmpty {
                    songs = remoteSongs
                } else if !localSongs.isEmpty {
                    songs = localSongs
                } else {
                    throw ShortcutPlaybackError.notFound
                }
            }
            try validateFlight(flightID, serverConfigID: serverConfigID)
            try await start(songs: songs, order: order)

        case .radio:
            if OfflineModeService.shared.isOffline {
                throw ShortcutPlaybackError.radioUnavailableOffline
            }
            try await requireNetwork()
            if RadioStationStore.shared.items.isEmpty {
                await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            }
            try validateFlight(flightID, serverConfigID: serverConfigID)
            guard let station = RadioStationStore.shared.items.first(where: { $0.id == reference.contentID }) else {
                throw ShortcutPlaybackError.notFound
            }
            try await requireStarted(AudioPlayerService.shared.playRadioStationAndWait(station))
        }
    }

    private func localPlaylistSongs(
        playlistID: String,
        downloaded: DownloadStore
    ) async -> [Song] {
        let cachedPlaylist = await LibraryStore.shared.loadCachedPlaylistDetail(id: playlistID)
        let downloadedIDs = Set(downloaded.songs.map(\.songId))
        let cachedSongs = (cachedPlaylist?.songs ?? []).filter {
            downloadedIDs.contains($0.id)
        }
        guard cachedSongs.isEmpty else { return cachedSongs }

        let ids = downloaded.playlistSongIds[playlistID] ?? []
        let localByID = Dictionary(
            downloaded.songs.map { ($0.songId, $0.asSong()) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { localByID[$0] }
    }

    private func start(songs: [Song], order: ShortcutPlaybackOrder) async throws {
        guard !songs.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }
        let outcome: PlaybackStartOutcome
        switch order {
        case .inOrder:
            outcome = await AudioPlayerService.shared.playAndWait(songs: songs)
        case .shuffled:
            outcome = await AudioPlayerService.shared.playShuffledAndWait(songs: songs)
        }
        try requireStarted(outcome)
    }

    private func play(
        _ mix: ShortcutSmartMix,
        server: SubsonicServer,
        flightID: UInt64
    ) async throws {
        try await requireNetwork()
        let songs: [Song]
        switch mix {
        case .newest:
            songs = try await SubsonicAPIService.shared.getNewestSongs()
        case .frequent:
            songs = try await frequentMixSongs(serverID: storageServerID(for: server))
        case .recent:
            songs = try await recentMixSongs(serverID: storageServerID(for: server))
        case .shuffleAll:
            songs = try await SubsonicAPIService.shared.getRandomSongs(size: 500)
        }
        try validateFlight(flightID, serverConfigID: server.id.uuidString)
        guard !songs.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }
        try await requireStarted(AudioPlayerService.shared.playShuffledAndWait(songs: songs))
    }

    private func frequentMixSongs(serverID: String) async throws -> [Song] {
        if UserDefaults.standard.bool(forKey: "mixUseDatabase"),
           await PlayLogService.shared.distinctSongCount(serverId: serverID) >= 50 {
            let counts = await PlayLogService.shared.topSongs(
                serverId: serverID,
                from: .distantPast,
                to: Date(),
                limit: 50
            )
            if !counts.isEmpty {
                return try await SubsonicAPIService.shared.getSongsOrdered(ids: counts.map(\.songId))
            }
        }

        let albums = try await SubsonicAPIService.shared.getAlbumList(type: "frequent", size: 500)
        let sorted = albums.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        let threshold = max((sorted.first?.playCount ?? 0) / 50, 1)
        var filtered = sorted.filter { ($0.playCount ?? 0) >= threshold }
        if filtered.count < 30 { filtered = Array(sorted.prefix(30)) }
        if filtered.count > 80 { filtered = Array(sorted.prefix(80)) }

        let songs = await withTaskGroup(of: [Song].self) { group in
            for album in filtered {
                group.addTask {
                    (try? await SubsonicAPIService.shared.getAlbum(id: album.id).song) ?? []
                }
            }
            var all: [Song] = []
            for await albumSongs in group { all.append(contentsOf: albumSongs) }
            return all
        }
        return Array(songs.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(50))
    }

    private func recentMixSongs(serverID: String) async throws -> [Song] {
        if UserDefaults.standard.bool(forKey: "mixUseDatabase"),
           await PlayLogService.shared.distinctSongCount(serverId: serverID) >= 50 {
            let ids = await PlayLogService.shared.recentUniqueSongIds(serverId: serverID, limit: 50)
            if !ids.isEmpty {
                return try await SubsonicAPIService.shared.getSongsOrdered(ids: ids)
            }
        }
        return try await SubsonicAPIService.shared.getRecentSongs(limit: 50)
    }

    private func playDownloads(
        _ mode: ShortcutDownloadsMode,
        server: SubsonicServer,
        flightID: UInt64
    ) async throws {
        try validateFlight(flightID, serverConfigID: server.id.uuidString)
        let downloads = DownloadStore.shared.songs
        guard !downloads.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }

        switch mode {
        case .all:
            let songs = downloads.map { $0.asSong() }.sorted(by: Self.downloadSort)
            try await requireStarted(AudioPlayerService.shared.playAndWait(songs: Array(songs.prefix(500))))
        case .shuffled:
            let songs = Array(downloads.shuffled().prefix(500)).map { $0.asSong() }
            try await requireStarted(AudioPlayerService.shared.playShuffledAndWait(songs: songs))
        case .newest:
            let songs = downloads.sorted { $0.addedAt > $1.addedAt }.prefix(100).map { $0.asSong() }
            try await requireStarted(AudioPlayerService.shared.playShuffledAndWait(songs: Array(songs)))
        }
    }

    private static func downloadSort(_ lhs: Song, _ rhs: Song) -> Bool {
        let leftArtist = stripArticle(lhs.artist ?? "")
        let rightArtist = stripArticle(rhs.artist ?? "")
        let artistOrder = leftArtist.localizedStandardCompare(rightArtist)
        if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
        let albumOrder = (lhs.album ?? "").localizedStandardCompare(rhs.album ?? "")
        if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
        if (lhs.discNumber ?? 0) != (rhs.discNumber ?? 0) {
            return (lhs.discNumber ?? 0) < (rhs.discNumber ?? 0)
        }
        return (lhs.track ?? 0) < (rhs.track ?? 0)
    }

    private func storageServerID(for server: SubsonicServer) -> String {
        server.stableId.isEmpty ? server.id.uuidString : server.stableId
    }

    private func playInstantMix(
        _ reference: ShortcutPlayableReference,
        server: SubsonicServer,
        flightID: UInt64
    ) async throws {
        guard !OfflineModeService.shared.isOffline else {
            throw ShortcutPlaybackError.unavailableOffline
        }
        try await requireNetwork()

        let songs: [Song]
        switch reference.kind {
        case .song:
            let song = try await SubsonicAPIService.shared.getSong(id: reference.contentID)
            songs = await InstantMixService.songMix(for: song)
        case .album:
            let detail = try await SubsonicAPIService.shared.getAlbum(id: reference.contentID)
            let album = Album(
                id: detail.id,
                name: detail.name,
                artist: detail.artist,
                artistId: detail.artistId,
                coverArt: detail.coverArt,
                songCount: detail.songCount,
                duration: detail.duration,
                year: detail.year,
                genre: detail.genre,
                songs: detail.song
            )
            songs = await InstantMixService.albumMix(for: album)
        case .artist:
            let detail = try await SubsonicAPIService.shared.getArtist(id: reference.contentID)
            let artist = Artist(
                id: detail.id,
                name: detail.name,
                albumCount: detail.albumCount,
                coverArt: detail.coverArt
            )
            songs = await InstantMixService.artistMix(for: artist)
        case .playlist, .radio:
            throw ShortcutPlaybackError.noPlayableContent
        }

        try validateFlight(flightID, serverConfigID: server.id.uuidString)
        guard !songs.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }
        try await requireStarted(AudioPlayerService.shared.playAndWait(songs: songs))
    }

    private func performPlayPause() async throws {
        let player = AudioPlayerService.shared
        guard player.hasActivePlayback else { throw ShortcutPlaybackError.noPlayableContent }
        try requireStarted(await player.togglePlayPauseAndWait())
    }

    private func performSkip(next: Bool) async throws {
        let player = AudioPlayerService.shared
        guard player.hasActivePlayback else { throw ShortcutPlaybackError.noPlayableContent }
        if !player.isRadioPlayback, next {
            guard player.hasNextTrack else { throw ShortcutPlaybackError.noPlayableContent }
        }
        let outcome = next ? await player.nextAndWait() : await player.previousAndWait()
        try requireStarted(outcome)
    }

    private func requireStarted(_ outcome: PlaybackStartOutcome) throws {
        switch outcome {
        case .started:
            return
        case .failed(let failure):
            switch failure {
            case .noActiveServer: throw ShortcutPlaybackError.noActiveServer
            case .emptyQueue: throw ShortcutPlaybackError.noPlayableContent
            case .unavailableOffline: throw ShortcutPlaybackError.unavailableOffline
            case .timedOut: throw ShortcutPlaybackError.playbackTimedOut
            case .serverChanged: throw ShortcutPlaybackError.serverChanged
            case .superseded, .cancelled: throw ShortcutPlaybackError.cancelled
            case .audioSessionUnavailable, .streamURLUnavailable,
                 .streamPreparationFailed, .engineFailed:
                throw ShortcutPlaybackError.playbackFailed
            }
        }
    }
}
