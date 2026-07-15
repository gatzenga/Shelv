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
        let action = command.diagnosticAction
        ShelvIntentDiagnostics.began(action: action, reference: command.diagnosticReference)
        do {
            try await execute(.command(command))
            ShelvIntentDiagnostics.completed(action: action)
        } catch let error as ShortcutPlaybackError {
            ShelvIntentDiagnostics.failed(action: action, error: error)
            throw error
        }
    }

    func play(
        _ reference: ShortcutPlayableReference,
        order: ShortcutPlaybackOrder,
        placement: ShortcutQueuePlacement = .replace,
        repeats: Bool = false
    ) async throws {
        let action = order == .shuffled ? "media.shuffle" : "media.play"
        ShelvIntentDiagnostics.began(action: action, reference: reference)
        do {
            try await execute(.playable(reference, order: order, placement: placement, repeats: repeats))
            ShelvIntentDiagnostics.completed(action: action)
        } catch let error as ShortcutPlaybackError {
            ShelvIntentDiagnostics.failed(action: action, error: error)
            throw error
        }
    }

    private func execute(_ request: Request) async throws {
        #if os(iOS) || os(tvOS)
        SiriMediaAppSelectionService.shared.beginSystemIntent()
        defer { SiriMediaAppSelectionService.shared.endSystemIntent() }
        #endif

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
                return .failure(.remoteFailure(error))
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

    private struct ServerContext {
        let server: SubsonicServer
        let storageServerID: String
        let records: [DownloadRecord]
    }

    private func prepareServer(
        expectedConfigID: String?,
        flightID: UInt64
    ) async throws -> ServerContext {
        let serverStore = ServerStore.shared
        await serverStore.waitUntilReady()
        guard let server = serverStore.activeServer else {
            throw ShortcutPlaybackError.noActiveServer
        }
        if let expectedConfigID, expectedConfigID != server.id.uuidString {
            throw ShortcutPlaybackError.serverChanged
        }
        await DownloadDatabase.shared.setup()
        await PlayLogService.shared.setup()
        let storageServerID = server.stableId.isEmpty ? server.id.uuidString : server.stableId
        let downloads = await LocalDownloadCatalog.load(serverId: storageServerID)
        try validateFlight(flightID, serverConfigID: server.id.uuidString)
        LocalDownloadIndex.shared.replace(
            serverId: storageServerID,
            pathsBySongId: downloads.pathsBySongId
        )
        return ServerContext(
            server: server,
            storageServerID: storageServerID,
            records: downloads.records
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
        let records = context.records
        let mayLoadRemote = await networkAvailable()

        if reference.kind == .radio {
            guard placement == .replace else { throw ShortcutPlaybackError.unsupportedQueueOperation }
            guard mayLoadRemote else { throw ShortcutPlaybackError.radioUnavailableOffline }
            if RadioStationStore.shared.items.isEmpty {
                await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            }
            try validateFlight(flightID, serverConfigID: context.server.id.uuidString)
            guard let station = RadioStationStore.shared.items.first(where: { $0.id == reference.contentID }) else {
                throw ShortcutPlaybackError.notFound
            }
            try requireStarted(await AudioPlayerService.shared.startRadioStationForSystemIntent(station))
            return
        }

        let songs = try await songs(
            for: reference,
            records: records,
            storageServerID: context.storageServerID,
            mayLoadRemote: mayLoadRemote
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
        storageServerID: String,
        mayLoadRemote: Bool
    ) async throws -> [Song] {
        let local: [Song]
        switch reference.kind {
        case .song:
            local = records.first(where: { $0.songId == reference.contentID })
                .map { [$0.toDownloadedSong().asSong()] } ?? []
        case .album:
            local = records.filter { $0.albumId == reference.contentID }
                .map { $0.toDownloadedSong().asSong() }
                .sorted(by: Self.albumTrackSort)
        case .artist:
            local = records.filter { $0.artistId == reference.contentID }
                .map { $0.toDownloadedSong().asSong() }
                .sorted(by: Self.downloadSort)
        case .playlist:
            local = localPlaylistSongs(
                playlistID: reference.contentID,
                records: records,
                storageServerID: storageServerID
            )
        case .radio:
            throw ShortcutPlaybackError.unsupportedQueueOperation
        }

        guard mayLoadRemote else {
            guard !local.isEmpty else { throw ShortcutPlaybackError.unavailableOffline }
            return local
        }

        let api = SubsonicAPIService.shared
        let artistAlbumPreference = ArtistAlbumPlaybackOrder.storedPreference()
        let provider = PlaybackContentProvider(
            song: { try await api.getSong(id: $0) },
            albumSongs: { try await api.getAlbum(id: $0).song ?? [] },
            artistAlbums: { artistID in
                let albums = try await api.getArtist(id: artistID).album ?? []
                return ArtistAlbumPlaybackOrder.sorted(
                    albums,
                    preference: artistAlbumPreference
                )
            },
            playlistSongs: { try await api.getPlaylist(id: $0).songs ?? [] }
        )
        do {
            let remote = try await PlaybackContentResolver.songs(
                for: reference.kind,
                contentID: reference.contentID,
                provider: provider
            )
            if !remote.isEmpty { return remote }
            guard !local.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }
            return local
        } catch let error as ShortcutPlaybackError {
            throw error
        } catch {
            guard !local.isEmpty else { throw ShortcutPlaybackError.remoteFailure(error) }
            return local
        }
    }

    private func localPlaylistSongs(
        playlistID: String,
        records: [DownloadRecord],
        storageServerID: String?
    ) -> [Song] {
        guard let storageServerID else { return [] }
        let orderedIDs = LocalOfflinePlaylistCatalog.songIds(
            serverId: storageServerID
        )[playlistID] ?? []
        guard !orderedIDs.isEmpty else { return [] }
        let songsByID = Dictionary(
            records.map { ($0.songId, $0.toDownloadedSong().asSong()) },
            uniquingKeysWith: { first, _ in first }
        )
        return orderedIDs.compactMap { songsByID[$0] }
    }

    private func apply(
        songs: [Song],
        order: ShortcutPlaybackOrder,
        placement: ShortcutQueuePlacement,
        repeats: Bool
    ) async throws {
        guard !songs.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }
        let player = AudioPlayerService.shared

        if placement != .replace, player.isRadioPlayback {
            throw ShortcutPlaybackError.unsupportedQueueOperation
        }
        if placement != .replace, player.hasActivePlayback {
            let queuedSongs = order == .shuffled ? songs.shuffled() : songs
            switch placement {
            case .next:
                player.addPlayNext(queuedSongs)
            case .tail:
                player.addToQueue(queuedSongs)
            case .replace:
                break
            }
            if repeats { player.repeatMode = .all }
            return
        }

        let outcome: PlaybackStartOutcome
        switch order {
        case .inOrder:
            outcome = await player.playAndWait(songs: songs)
        case .shuffled:
            outcome = await player.playShuffledAndWait(songs: songs)
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
        let songs = try await SmartMixPlaybackService.songs(
            for: mix,
            storageServerID: context.storageServerID
        )
        try validateFlight(flightID, serverConfigID: context.server.id.uuidString)
        try await apply(songs: songs, order: .shuffled, placement: .replace, repeats: false)
    }

    private func playDownloads(
        _ mode: ShortcutDownloadsMode,
        context: ServerContext,
        flightID: UInt64
    ) async throws {
        let records = context.records
        try validateFlight(flightID, serverConfigID: context.server.id.uuidString)
        guard !records.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }
        let selection = DownloadedPlaybackQueueBuilder.selection(from: records, mode: mode)
        try await apply(
            songs: selection.songs,
            order: selection.order,
            placement: .replace,
            repeats: false
        )
    }

    private static func downloadSort(_ lhs: Song, _ rhs: Song) -> Bool {
        let leftArtist = LibrarySortKey.removingLeadingArticle(from: lhs.artist ?? "")
        let rightArtist = LibrarySortKey.removingLeadingArticle(from: rhs.artist ?? "")
        let artistOrder = leftArtist.localizedStandardCompare(rightArtist)
        if artistOrder != .orderedSame { return artistOrder == .orderedAscending }

        let albumOrder = (lhs.album ?? "").localizedStandardCompare(rhs.album ?? "")
        if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
        if (lhs.discNumber ?? 1) != (rhs.discNumber ?? 1) {
            return (lhs.discNumber ?? 1) < (rhs.discNumber ?? 1)
        }
        if (lhs.track ?? Int.max) != (rhs.track ?? Int.max) {
            return (lhs.track ?? Int.max) < (rhs.track ?? Int.max)
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func albumTrackSort(_ lhs: Song, _ rhs: Song) -> Bool {
        if (lhs.discNumber ?? 1) != (rhs.discNumber ?? 1) {
            return (lhs.discNumber ?? 1) < (rhs.discNumber ?? 1)
        }
        if (lhs.track ?? Int.max) != (rhs.track ?? Int.max) {
            return (lhs.track ?? Int.max) < (rhs.track ?? Int.max)
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
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
            let song = try await SubsonicAPIService.shared.getSong(
                id: reference.contentID,
                retries: 1
            )
            songs = await InstantMixService.songMix(for: song)
        case .album:
            let detail = try await SubsonicAPIService.shared.getAlbum(
                id: reference.contentID,
                retries: 1
            )
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
            let detail = try await SubsonicAPIService.shared.getArtist(
                id: reference.contentID,
                retries: 1
            )
            songs = await InstantMixService.artistMix(for: Artist(
                id: detail.id,
                name: detail.name,
                albumCount: detail.albumCount,
                coverArt: detail.coverArt
            ))
        case .playlist, .radio:
            throw ShortcutPlaybackError.noPlayableContent
        }
        ShelvIntentDiagnostics.instantMixBuilt(kind: reference.kind, trackCount: songs.count)
        guard songs.count > 1 else {
            throw ShortcutPlaybackError.instantMixUnavailable
        }
        try validateFlight(flightID, serverConfigID: context.server.id.uuidString)
        try await apply(songs: songs, order: .inOrder, placement: .replace, repeats: false)
        guard AudioPlayerService.shared.hasNextTrack else {
            AudioPlayerService.shared.stop()
            throw ShortcutPlaybackError.instantMixUnavailable
        }
        ShelvIntentDiagnostics.instantMixPlaybackConfirmed(trackCount: songs.count)
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
