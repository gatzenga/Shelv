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

    /// A track list Siri asked us to prepare ahead of the actual play request.
    private struct WarmedQueue {
        let serverConfigID: String
        let reference: ShortcutPlayableReference
        let songs: [Song]
        let expiry: ContinuousClock.Instant
    }

    private var nextFlightID: UInt64 = 0
    private var flight: Flight?
    private var warmedQueue: WarmedQueue?
    /// Result of the flight that is currently being waited on. Only the newest
    /// flight can have an entry, because starting one cancels its predecessor.
    private var finishedFlight: (id: UInt64, result: Result<Void, ShortcutPlaybackError>)?

    private init() {}

    /// Resolves and caches the tracks for `reference` so a following play
    /// request can skip the server round trip. Siri calls this while it is
    /// still talking to the person, which is what keeps the later answer inside
    /// the system's deadline on a self-hosted server.
    func warmUpQueue(for reference: ShortcutPlayableReference) async throws {
        let serverStore = ServerStore.shared
        await serverStore.waitUntilReady()
        guard let server = serverStore.activeServer else {
            throw ShortcutPlaybackError.noActiveServer
        }
        guard reference.serverConfigID == server.id.uuidString else {
            throw ShortcutPlaybackError.serverChanged
        }

        // A live stream has no track list to prepare; warming the station
        // catalog is the equivalent piece of work.
        guard reference.kind != .radio else {
            if RadioStationStore.shared.items.isEmpty, await networkAvailable() {
                await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            }
            return
        }

        await DownloadDatabase.shared.setup()
        let storageServerID = server.stableId.isEmpty ? server.id.uuidString : server.stableId
        let downloads = await LocalDownloadCatalog.load(serverId: storageServerID)
        LocalDownloadIndex.shared.replace(
            serverId: storageServerID,
            pathsBySongId: downloads.pathsBySongId
        )
        let songs = try await songs(
            for: reference,
            records: downloads.records,
            storageServerID: storageServerID,
            mayLoadRemote: await networkAvailable()
        )
        guard !songs.isEmpty else { throw ShortcutPlaybackError.noPlayableContent }
        guard ServerStore.shared.activeServer?.id == server.id else {
            throw ShortcutPlaybackError.serverChanged
        }
        warmedQueue = WarmedQueue(
            serverConfigID: server.id.uuidString,
            reference: reference,
            songs: songs,
            expiry: ContinuousClock().now.advanced(by: .seconds(90))
        )
        ShelvIntentDiagnostics.queueWarmed(kind: reference.kind, trackCount: songs.count)
    }

    /// Resolves the tracks behind a reference without starting playback. Shared
    /// with the library-editing intents so they see exactly the same content
    /// Siri would have played.
    func resolvedSongs(for reference: ShortcutPlayableReference) async throws -> [Song] {
        let serverStore = ServerStore.shared
        await serverStore.waitUntilReady()
        guard let server = serverStore.activeServer else {
            throw ShortcutPlaybackError.noActiveServer
        }
        guard reference.serverConfigID == server.id.uuidString else {
            throw ShortcutPlaybackError.serverChanged
        }
        await DownloadDatabase.shared.setup()
        let storageServerID = server.stableId.isEmpty ? server.id.uuidString : server.stableId
        let downloads = await LocalDownloadCatalog.load(serverId: storageServerID)
        return try await songs(
            for: reference,
            records: downloads.records,
            storageServerID: storageServerID,
            mayLoadRemote: await networkAvailable()
        )
    }

    private func consumeWarmedQueue(for reference: ShortcutPlayableReference) -> [Song]? {
        guard let warmed = warmedQueue else { return nil }
        warmedQueue = nil
        guard warmed.reference == reference,
              warmed.expiry > ContinuousClock().now,
              warmed.serverConfigID == ServerStore.shared.activeServer?.id.uuidString
        else { return nil }
        ShelvIntentDiagnostics.warmedQueueUsed(trackCount: warmed.songs.count)
        return warmed.songs
    }

    func execute(
        _ command: ShortcutPlaybackCommand,
        budget: ShortcutIntentBudget = .appIntent
    ) async throws {
        let action = command.diagnosticAction
        ShelvIntentDiagnostics.began(action: action, reference: command.diagnosticReference)
        do {
            try await execute(.command(command), action: action, budget: budget)
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
        repeats: Bool = false,
        budget: ShortcutIntentBudget = .appIntent
    ) async throws {
        let action = order == .shuffled ? "media.shuffle" : "media.play"
        ShelvIntentDiagnostics.began(action: action, reference: reference)
        do {
            try await execute(
                .playable(reference, order: order, placement: placement, repeats: repeats),
                action: action,
                budget: budget
            )
            ShelvIntentDiagnostics.completed(action: action)
        } catch let error as ShortcutPlaybackError {
            ShelvIntentDiagnostics.failed(action: action, error: error)
            throw error
        }
    }

    private func execute(
        _ request: Request,
        action: String,
        budget: ShortcutIntentBudget
    ) async throws {
        #if os(iOS) || os(tvOS)
        SiriMediaAppSelectionService.shared.beginSystemIntent()
        defer { SiriMediaAppSelectionService.shared.endSystemIntent() }
        #endif

        nextFlightID &+= 1
        let flightID = nextFlightID
        flight?.task.cancel()
        finishedFlight = nil

        let task = Task { @MainActor [weak self] () -> Result<Void, ShortcutPlaybackError> in
            guard let self else { return .failure(.cancelled) }
            let outcome: Result<Void, ShortcutPlaybackError>
            do {
                try await self.runWithWorkCeiling(request, flightID: flightID)
                outcome = .success(())
            } catch let error as ShortcutPlaybackError {
                outcome = .failure(error)
            } catch is CancellationError {
                outcome = .failure(.cancelled)
            } catch {
                outcome = .failure(.remoteFailure(error))
            }
            if self.flight?.id == flightID { self.flight = nil }
            self.finishedFlight = (flightID, outcome)
            return outcome
        }
        flight = Flight(id: flightID, task: task)

        let result = await withTaskCancellationHandler {
            await awaitFlight(flightID, within: budget.responseDeadline)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.flight?.id == flightID else { return }
                self?.flight?.task.cancel()
            }
        }
        if Task.isCancelled { throw ShortcutPlaybackError.cancelled }
        guard let result else {
            // The answer deadline passed while the track is still being
            // prepared. The flight is deliberately left running, so reporting
            // success is the truthful answer: the audio does start moments
            // later. Reporting a failure here would make Siri talk over music
            // that is already playing.
            ShelvIntentDiagnostics.answeredWhileStarting(action: action, budget: budget)
            return
        }
        switch result {
        case .success: return
        case .failure(let error): throw error
        }
    }

    /// Waits for a flight to report back, giving up after `duration`.
    ///
    /// Polling instead of awaiting the task directly is deliberate: `Task.value`
    /// ignores cancellation, and a task group would keep waiting for that child
    /// when the body returns — either would defeat the deadline and abort or
    /// delay playback that is on its way.
    private func awaitFlight(
        _ flightID: UInt64,
        within duration: Duration
    ) async -> Result<Void, ShortcutPlaybackError>? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if Task.isCancelled { return .failure(.cancelled) }
            if let finished = finishedFlight, finished.id == flightID {
                finishedFlight = nil
                return finished.result
            }
            // A newer request took over. Waiting out the deadline would report
            // success for work that was cancelled, so say so immediately.
            if let current = flight, current.id != flightID {
                return .failure(.cancelled)
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return .failure(.cancelled)
            }
        }
        return nil
    }

    /// Upper bound for the background work itself. It only stops a flight that
    /// hangs; the system has long been answered by the time it fires.
    private func runWithWorkCeiling(_ request: Request, flightID: UInt64) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw ShortcutPlaybackError.cancelled }
                try await self.run(request, flightID: flightID)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
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

        // Only playback consumes what Siri asked us to warm up. Library edits
        // resolve their own copy so they cannot spend the prepared queue.
        let songs: [Song]
        if let warmed = consumeWarmedQueue(for: reference) {
            songs = warmed
        } else {
            songs = try await self.songs(
                for: reference,
                records: records,
                storageServerID: context.storageServerID,
                mayLoadRemote: mayLoadRemote
            )
        }
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
        let songs = try await SmartMixPlaybackService.songs(for: mix)
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
