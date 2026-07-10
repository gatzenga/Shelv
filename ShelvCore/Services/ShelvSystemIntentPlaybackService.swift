import Foundation

/// Playback boundary for system intents shared by macOS, tvOS and the new
/// iOS/macOS audio schema. It deliberately uses only shared services and the
/// download database, so it can run before any platform UI store exists.
@MainActor
final class ShelvSystemIntentPlaybackService: @unchecked Sendable {
    static let shared = ShelvSystemIntentPlaybackService()

    private enum Request: Hashable, Sendable {
        case command(ShortcutPlaybackCommand)
        case playable(
            ShortcutPlayableReference,
            order: ShortcutPlaybackOrder,
            placement: ShortcutQueuePlacement,
            repeats: Bool
        )
    }

    private struct Flight {
        let id: UInt64
        let task: Task<Result<Void, ShortcutPlaybackError>, Never>
    }

    private var nextFlightID: UInt64 = 0
    private var flight: Flight?

    private init() {}

    func execute(_ command: ShortcutPlaybackCommand) async throws {
        try await execute(.command(command))
    }

    func play(
        _ reference: ShortcutPlayableReference,
        order: ShortcutPlaybackOrder,
        placement: ShortcutQueuePlacement = .replace,
        repeats: Bool = false
    ) async throws {
        try await execute(.playable(reference, order: order, placement: placement, repeats: repeats))
    }

    private func execute(_ request: Request) async throws {
        nextFlightID &+= 1
        let flightID = nextFlightID
        flight?.task.cancel()

        let task = Task { @MainActor [weak self] () -> Result<Void, ShortcutPlaybackError> in
            guard let self else { return .failure(.cancelled) }
            do {
                try await self.runWithDeadline(request, flightID: flightID)
                return .success(())
            } catch let error as ShortcutPlaybackError {
                return .failure(error)
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch {
                return .failure(.playbackFailed)
            }
        }
        flight = Flight(id: flightID, task: task)

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.flight?.id == flightID else { return }
                self?.flight?.task.cancel()
            }
        }
        if flight?.id == flightID { flight = nil }
        if Task.isCancelled { throw ShortcutPlaybackError.cancelled }
        switch result {
        case .success: return
        case .failure(let error): throw error
        }
    }

    private func runWithDeadline(_ request: Request, flightID: UInt64) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw ShortcutPlaybackError.cancelled }
                try await self.run(request, flightID: flightID)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(25))
                throw ShortcutPlaybackError.playbackTimedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func run(_ request: Request, flightID: UInt64) async throws {
        switch request {
        case .playable(let reference, let order, let placement, let repeats):
            let context = try await prepareServer(
                expectedConfigID: reference.serverConfigID,
                flightID: flightID
            )
            try await play(
                reference,
                order: order,
                placement: placement,
                repeats: repeats,
                context: context,
                flightID: flightID
            )

        case .command(let command):
            switch command {
            case .playable(let reference, let order):
                let context = try await prepareServer(
                    expectedConfigID: reference.serverConfigID,
                    flightID: flightID
                )
                try await play(
                    reference,
                    order: order,
                    placement: .replace,
                    repeats: false,
                    context: context,
                    flightID: flightID
                )
            case .mix(let mix):
                let context = try await prepareServer(expectedConfigID: nil, flightID: flightID)
                try await play(mix, context: context, flightID: flightID)
            case .downloads(let mode):
                let context = try await prepareServer(expectedConfigID: nil, flightID: flightID)
                try await playDownloads(mode, context: context, flightID: flightID)
            case .instantMix(let reference):
                let context = try await prepareServer(
                    expectedConfigID: reference.serverConfigID,
                    flightID: flightID
                )
                try await playInstantMix(reference, context: context, flightID: flightID)
            case .playPause:
                try await performPlayPause()
            case .next:
                try await performSkip(next: true)
            case .previous:
                try await performSkip(next: false)
            }
        }
    }

    private typealias ServerContext = (server: SubsonicServer, storageServerID: String)

    private func prepareServer(
        expectedConfigID: String?,
        flightID: UInt64
    ) async throws -> ServerContext {
        _ = ServerStore.shared
        guard let server = ServerStore.shared.activeServer else {
            throw ShortcutPlaybackError.noActiveServer
        }
        if let expectedConfigID, expectedConfigID != server.id.uuidString {
            throw ShortcutPlaybackError.serverChanged
        }
        await DownloadDatabase.shared.setup()
        await PlayLogService.shared.setup()
        try validateFlight(flightID, serverConfigID: server.id.uuidString)
        return (
            server,
            server.stableId.isEmpty ? server.id.uuidString : server.stableId
        )
    }

    private func validateFlight(_ flightID: UInt64, serverConfigID: String) throws {
        guard !Task.isCancelled, flight?.id == flightID else {
            throw ShortcutPlaybackError.cancelled
        }
        guard ServerStore.shared.activeServer?.id.uuidString == serverConfigID else {
            throw ShortcutPlaybackError.serverChanged
        }
    }

    private func networkAvailable() async -> Bool {
        guard !OfflineModeService.shared.isOffline else { return false }
        return await NetworkStatus.shared.waitUntilNetworkAvailable()
    }

    private func requireNetwork() async throws {
        guard await networkAvailable() else { throw ShortcutPlaybackError.noNetwork }
    }

    private func play(
        _ reference: ShortcutPlayableReference,
        order: ShortcutPlaybackOrder,
        placement: ShortcutQueuePlacement,
        repeats: Bool,
        context: ServerContext,
        flightID: UInt64
    ) async throws {
        let records = await DownloadDatabase.shared.allRecords(serverId: context.storageServerID)
        let hasNetwork = await networkAvailable()

        if reference.kind == .radio {
            guard placement == .replace else { throw ShortcutPlaybackError.unsupportedQueueOperation }
            guard hasNetwork else { throw ShortcutPlaybackError.radioUnavailableOffline }
            if RadioStationStore.shared.items.isEmpty {
                await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            }
            try validateFlight(flightID, serverConfigID: context.server.id.uuidString)
            guard let station = RadioStationStore.shared.items.first(where: { $0.id == reference.contentID }) else {
                throw ShortcutPlaybackError.notFound
            }
            try requireStarted(await AudioPlayerService.shared.playRadioStationAndWait(station))
            return
        }

        let songs = try await songs(
            for: reference,
            records: records,
            hasNetwork: hasNetwork
        )
        try validateFlight(flightID, serverConfigID: context.server.id.uuidString)
        try await apply(
            songs: songs,
            order: order,
            placement: placement,
            repeats: repeats
        )
    }

    private func songs(
        for reference: ShortcutPlayableReference,
        records: [DownloadRecord],
        hasNetwork: Bool
    ) async throws -> [Song] {
        switch reference.kind {
        case .song:
            let local = records.first(where: { $0.songId == reference.contentID })?
                .toDownloadedSong().asSong()
            if hasNetwork, let remote = try? await SubsonicAPIService.shared.getSong(id: reference.contentID) {
                return [remote]
            }
            guard let local else { throw ShortcutPlaybackError.unavailableOffline }
            return [local]

        case .album:
            let local = records.filter { $0.albumId == reference.contentID }
                .map { $0.toDownloadedSong().asSong() }
            if hasNetwork,
               let remote = try? await SubsonicAPIService.shared.getAlbum(id: reference.contentID).song,
               !remote.isEmpty {
                return remote
            }
            guard !local.isEmpty else { throw ShortcutPlaybackError.unavailableOffline }
            return local

        case .artist:
            let local = records.filter { $0.artistId == reference.contentID }
                .map { $0.toDownloadedSong().asSong() }
            if hasNetwork,
               let detail = try? await SubsonicAPIService.shared.getArtist(id: reference.contentID),
               let remote = try? await SubsonicAPIService.shared.getTopSongs(
                   artistName: detail.name,
                   count: 100
               ),
               !remote.isEmpty {
                return remote
            }
            guard !local.isEmpty else { throw ShortcutPlaybackError.unavailableOffline }
            return local

        case .playlist:
            guard hasNetwork else { throw ShortcutPlaybackError.unavailableOffline }
            guard let playlist = try? await SubsonicAPIService.shared.getPlaylist(id: reference.contentID),
                  let songs = playlist.songs,
                  !songs.isEmpty
            else { throw ShortcutPlaybackError.notFound }
            return songs

        case .radio:
            throw ShortcutPlaybackError.unsupportedQueueOperation
        }
    }

    private func apply(
        songs: [Song],
        order: ShortcutPlaybackOrder,
        placement: ShortcutQueuePlacement,
        repeats: Bool
    ) async throws {
        guard !songs.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }
        let orderedSongs = order == .shuffled ? songs.shuffled() : songs
        let player = AudioPlayerService.shared

        if placement != .replace, player.hasActivePlayback {
            switch placement {
            case .next:
                player.addPlayNext(orderedSongs)
            case .tail:
                player.addToQueue(orderedSongs)
            case .replace:
                break
            }
            if repeats { player.repeatMode = .all }
            return
        }

        let outcome: PlaybackStartOutcome
        switch order {
        case .inOrder:
            outcome = await player.playAndWait(songs: orderedSongs)
        case .shuffled:
            outcome = await player.playShuffledAndWait(songs: orderedSongs)
        }
        try requireStarted(outcome)
        player.repeatMode = repeats ? .all : .off
    }

    private func play(
        _ mix: ShortcutSmartMix,
        context: ServerContext,
        flightID: UInt64
    ) async throws {
        try await requireNetwork()
        let songs: [Song]
        switch mix {
        case .newest:
            songs = try await SubsonicAPIService.shared.getNewestSongs()
        case .frequent:
            songs = try await frequentSongs(serverID: context.storageServerID)
        case .recent:
            songs = try await recentSongs(serverID: context.storageServerID)
        case .shuffleAll:
            songs = try await SubsonicAPIService.shared.getRandomSongs(size: 500)
        }
        try validateFlight(flightID, serverConfigID: context.server.id.uuidString)
        try await apply(songs: songs, order: .shuffled, placement: .replace, repeats: false)
    }

    private func frequentSongs(serverID: String) async throws -> [Song] {
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
        return try await SubsonicAPIService.shared.getFrequentSongs(albumCount: 50, limit: 100)
    }

    private func recentSongs(serverID: String) async throws -> [Song] {
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
        context: ServerContext,
        flightID: UInt64
    ) async throws {
        let records = await DownloadDatabase.shared.allRecords(serverId: context.storageServerID)
        try validateFlight(flightID, serverConfigID: context.server.id.uuidString)
        guard !records.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }

        switch mode {
        case .all:
            let songs = records.map { $0.toDownloadedSong().asSong() }
            try await apply(
                songs: Array(songs.prefix(500)),
                order: .inOrder,
                placement: .replace,
                repeats: false
            )
        case .shuffled:
            let songs = records.shuffled().prefix(500).map { $0.toDownloadedSong().asSong() }
            try await apply(songs: songs, order: .shuffled, placement: .replace, repeats: false)
        case .newest:
            let songs = records.sorted { $0.addedAt > $1.addedAt }
                .prefix(100)
                .map { $0.toDownloadedSong().asSong() }
            try await apply(songs: songs, order: .shuffled, placement: .replace, repeats: false)
        }
    }

    private func playInstantMix(
        _ reference: ShortcutPlayableReference,
        context: ServerContext,
        flightID: UInt64
    ) async throws {
        try await requireNetwork()
        let songs: [Song]
        switch reference.kind {
        case .song:
            let song = try await SubsonicAPIService.shared.getSong(id: reference.contentID)
            songs = await InstantMixService.songMix(for: song)
        case .album:
            let detail = try await SubsonicAPIService.shared.getAlbum(id: reference.contentID)
            songs = await InstantMixService.albumMix(for: Album(
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
            ))
        case .artist:
            let detail = try await SubsonicAPIService.shared.getArtist(id: reference.contentID)
            songs = await InstantMixService.artistMix(for: Artist(
                id: detail.id,
                name: detail.name,
                albumCount: detail.albumCount,
                coverArt: detail.coverArt
            ))
        case .playlist, .radio:
            throw ShortcutPlaybackError.noPlayableContent
        }
        try validateFlight(flightID, serverConfigID: context.server.id.uuidString)
        try await apply(songs: songs, order: .inOrder, placement: .replace, repeats: false)
    }

    private func performPlayPause() async throws {
        let player = AudioPlayerService.shared
        guard player.hasActivePlayback else { throw ShortcutPlaybackError.noPlayableContent }
        try requireStarted(await player.togglePlayPauseAndWait())
    }

    private func performSkip(next: Bool) async throws {
        let player = AudioPlayerService.shared
        guard player.hasActivePlayback else { throw ShortcutPlaybackError.noPlayableContent }
        if !player.isRadioPlayback, next, !player.hasNextTrack {
            throw ShortcutPlaybackError.noPlayableContent
        }
        try requireStarted(next ? await player.nextAndWait() : await player.previousAndWait())
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
