import Foundation

nonisolated struct ShelvIntentCatalogItem: Hashable, Sendable {
    let reference: ShortcutPlayableReference
    let title: String
    let artistID: String?
    let artistName: String?
    let albumID: String?
    let albumTitle: String?
    let duration: TimeInterval?
    let itemCount: Int?
    let internationalStandardRecordingCode: String?

    var subtitle: String? {
        switch reference.kind {
        case .song:
            artistName
        case .album:
            artistName
        case .artist:
            String(localized: "shortcut_kind_artist")
        case .playlist:
            itemCount.map { String(format: String(localized: "shortcut_track_count_format"), $0) }
        case .radio:
            String(localized: "shortcut_kind_radio")
        }
    }
}

/// Shared catalog boundary used by macOS/tvOS App Shortcuts and by the
/// iOS/macOS 27 audio schema. It searches Navidrome when possible and falls
/// back to the download database without depending on a platform UI store.
@MainActor
final class ShelvIntentCatalog {
    static let shared = ShelvIntentCatalog()

    private let api = SubsonicAPIService.shared
    private init() {}

    func suggestedItems(
        limit: Int = 40,
        allowedKinds: Set<ShortcutPlayableKind> = Set(ShortcutPlayableKind.allCases)
    ) async throws -> [ShelvIntentCatalogItem] {
        let context = try await activeContext()
        let records = await LocalDownloadCatalog.load(
            serverId: context.storageServerID
        ).records
        var items: [ShelvIntentCatalogItem] = []
        if allowedKinds.contains(.song) {
            items += records.prefix(8).map {
                songItem($0.toDownloadedSong().asSong(), server: context.server)
            }
        }
        items += localCollectionItems(from: records, server: context.server)
            .filter { allowedKinds.contains($0.reference.kind) }
            .prefix(16)
        if allowedKinds.contains(.playlist) {
            let availableSongIDs = Set(records.map(\.songId))
            let playlists = await LocalOfflinePlaylistCatalog.descriptors(
                serverId: context.storageServerID,
                serverConfigID: context.server.id
            )
            items += playlists.filter {
                $0.songIds.contains(where: availableSongIDs.contains)
            }.map {
                localPlaylistItem($0, records: records, server: context.server)
            }
        }

        guard await networkAvailable() else {
            try validate(context)
            return balancedUnique(items, allowedKinds: allowedKinds, limit: limit)
        }

        let needsMusicCatalog = !allowedKinds.isDisjoint(with: [.song, .album, .artist])
        async let starredResult = needsMusicCatalog ? remoteStarred() : nil
        async let playlistsResult = allowedKinds.contains(.playlist) ? remotePlaylists() : []
        async let recentResult = needsMusicCatalog ? remoteRecentSongs() : []
        async let radioResult = allowedKinds.contains(.radio) ? remoteRadios() : []

        let (starred, playlists, recent, radios) = await (
            starredResult, playlistsResult, recentResult, radioResult
        )

        if let starred {
            if allowedKinds.contains(.song) {
                items += (starred.song ?? []).prefix(8).map { songItem($0, server: context.server) }
            }
            if allowedKinds.contains(.album) {
                items += (starred.album ?? []).prefix(6).map { albumItem($0, server: context.server) }
            }
            if allowedKinds.contains(.artist) {
                items += (starred.artist ?? []).prefix(6).map { artistItem($0, server: context.server) }
            }
        }
        if allowedKinds.contains(.playlist) {
            for playlist in playlists {
                await LocalOfflinePlaylistCatalog.updateName(
                    serverId: context.storageServerID,
                    id: playlist.id,
                    name: playlist.name
                )
            }
            items += playlists.prefix(8).map { playlistItem($0, server: context.server) }
        }
        let recentSongs = Array(recent.prefix(8))
        if allowedKinds.contains(.artist) {
            items += recentSongs.compactMap { artistItem(from: $0, server: context.server) }
        }
        if allowedKinds.contains(.album) {
            items += recentSongs.compactMap { albumItem(from: $0, server: context.server) }
        }
        if allowedKinds.contains(.song) {
            items += recentSongs.map { songItem($0, server: context.server) }
        }
        if allowedKinds.contains(.radio) {
            items += radios.prefix(6).map { radioItem($0, server: context.server) }
        }
        try validate(context)
        return balancedUnique(items, allowedKinds: allowedKinds, limit: limit)
    }

    func items(
        matching rawQuery: String,
        limit: Int = 60,
        requiresExplicitRadio: Bool = false,
        allowedKinds: Set<ShortcutPlayableKind> = Set(ShortcutPlayableKind.allCases)
    ) async throws -> [ShelvIntentCatalogItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try await suggestedItems(limit: limit, allowedKinds: allowedKinds)
        }

        let context = try await activeContext()
        let terms = ShelvIntentSearchVocabulary.searchTerms(for: query)
        let effectiveAllowedKinds = ShelvIntentSearchVocabulary.effectiveAllowedKinds(
            allowedKinds,
            for: query,
            requiresExplicitRadio: requiresExplicitRadio
        )
        guard !effectiveAllowedKinds.isEmpty else { return [] }
        let localRecords = await LocalDownloadCatalog.load(
            serverId: context.storageServerID
        ).records
        let validLocalSongIDs = Set(localRecords.map(\.songId))
        var scored: [ShortcutPlayableReference: (item: ShelvIntentCatalogItem, score: Int)] = [:]

        for term in terms {
            let records = await DownloadDatabase.shared.search(
                serverId: context.storageServerID,
                query: term,
                limit: 60
            ).filter { validLocalSongIDs.contains($0.songId) }
            for item in records.flatMap({ localItems(for: $0, server: context.server) }) {
                guard ShelvIntentSearchVocabulary.allows(
                    item.reference.kind,
                    for: query,
                    requiresExplicitRadio: requiresExplicitRadio
                ), effectiveAllowedKinds.contains(item.reference.kind) else { continue }
                merge(item, query: query, into: &scored)
            }
        }

        if effectiveAllowedKinds.contains(.playlist), ShelvIntentSearchVocabulary.allows(
            .playlist,
            for: query,
            requiresExplicitRadio: requiresExplicitRadio
        ) {
            let playlists = await LocalOfflinePlaylistCatalog.descriptors(
                serverId: context.storageServerID,
                serverConfigID: context.server.id
            )
            let availableSongIDs = Set(localRecords.map(\.songId))
            for playlist in playlists where playlist.songIds.contains(
                where: availableSongIDs.contains
            ) && matches(
                playlist.name ?? String(localized: "shortcut_kind_playlist"),
                query: query,
                terms: terms
            ) {
                merge(
                    localPlaylistItem(playlist, records: localRecords, server: context.server),
                    query: query,
                    into: &scored
                )
            }
        }

        if await networkAvailable() {
            let needsMusicCatalog = !effectiveAllowedKinds.isDisjoint(with: [.song, .album, .artist])
            async let searchResults = needsMusicCatalog ? remoteSearchResults(for: terms) : []
            async let playlists = effectiveAllowedKinds.contains(.playlist) ? remotePlaylists() : []
            async let radios = effectiveAllowedKinds.contains(.radio) ? remoteRadios() : []
            let (results, playlistResults, radioResults) = await (
                searchResults, playlists, radios
            )

            for result in results {
                for song in result.song ?? [] where ShelvIntentSearchVocabulary.allows(
                    .song,
                    for: query,
                    requiresExplicitRadio: requiresExplicitRadio
                ) && effectiveAllowedKinds.contains(.song) {
                    merge(songItem(song, server: context.server), query: query, into: &scored)
                }
                for album in result.album ?? [] where ShelvIntentSearchVocabulary.allows(
                    .album,
                    for: query,
                    requiresExplicitRadio: requiresExplicitRadio
                ) && effectiveAllowedKinds.contains(.album) {
                    merge(albumItem(album, server: context.server), query: query, into: &scored)
                }
                for artist in result.artist ?? [] where ShelvIntentSearchVocabulary.allows(
                    .artist,
                    for: query,
                    requiresExplicitRadio: requiresExplicitRadio
                ) && effectiveAllowedKinds.contains(.artist) {
                    merge(artistItem(artist, server: context.server), query: query, into: &scored)
                }
            }

            for playlist in playlistResults where ShelvIntentSearchVocabulary.allows(
                .playlist,
                for: query,
                requiresExplicitRadio: requiresExplicitRadio
            ) && effectiveAllowedKinds.contains(.playlist)
                && matches(playlist.name, query: query, terms: terms) {
                merge(playlistItem(playlist, server: context.server), query: query, into: &scored)
                await LocalOfflinePlaylistCatalog.updateName(
                    serverId: context.storageServerID,
                    id: playlist.id,
                    name: playlist.name
                )
            }
            for radio in radioResults where ShelvIntentSearchVocabulary.allows(
                .radio,
                for: query,
                requiresExplicitRadio: requiresExplicitRadio
            ) && effectiveAllowedKinds.contains(.radio)
                && matches(radio.name, query: query, terms: terms) {
                merge(radioItem(radio, server: context.server), query: query, into: &scored)
            }
        }

        try validate(context)
        let ranked = scored.values
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                let titleOrder = $0.item.title.localizedStandardCompare($1.item.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                let leftKind = $0.item.reference.kind.rawValue
                let rightKind = $1.item.reference.kind.rawValue
                if leftKind != rightKind { return leftKind < rightKind }
                return $0.item.reference.identifier < $1.item.reference.identifier
            }
        let primaryMatches = ranked.filter { value in
            ShelvIntentSearchRanking.isPrimaryMatch(
                kind: value.item.reference.kind,
                title: value.item.title,
                artistName: value.item.artistName,
                albumTitle: value.item.albumTitle,
                query: query
            )
        }
        let resolved = (primaryMatches.isEmpty ? ranked : primaryMatches)
            .prefix(limit)
            .map(\.item)
        ShelvIntentDiagnostics.catalogResolved(queryLength: query.count, resultCount: resolved.count)
        return resolved
    }

    /// Reduces a Siri playback search to one result when the request has one
    /// objectively best match. Genuine title ties remain available for system
    /// disambiguation instead of silently choosing the wrong song or album.
    nonisolated static func deterministicPlaybackMatches(
        _ items: [ShelvIntentCatalogItem],
        query: String,
        ambiguityLimit: Int = 5
    ) -> [ShelvIntentCatalogItem] {
        ShelvIntentSearchRanking.deterministicPlaybackMatches(
            items,
            query: query,
            ambiguityLimit: ambiguityLimit
        ) { item in
            (
                item.reference.kind,
                item.title,
                item.artistName,
                item.albumTitle
            )
        }
    }

    func items(for identifiers: [String]) async throws -> [ShelvIntentCatalogItem] {
        let references = identifiers.compactMap(ShortcutPlayableReference.init(identifier:))
        ShelvIntentDiagnostics.entityLookupBegan(
            identifierCount: identifiers.count,
            parsedCount: references.count
        )
        return try await items(for: references)
    }

    func items(for references: [ShortcutPlayableReference]) async throws -> [ShelvIntentCatalogItem] {
        do {
            let context = try await activeContext()
            let matching = references.filter { $0.serverConfigID == context.server.id.uuidString }
            guard !matching.isEmpty else {
                ShelvIntentDiagnostics.entityLookupCompleted(
                    requestedCount: references.count,
                    matchingServerCount: 0,
                    resultCount: 0
                )
                return []
            }
            let records = await LocalDownloadCatalog.load(
                serverId: context.storageServerID
            ).records
            let mayLoadRemote = await networkAvailable()

            var result: [ShelvIntentCatalogItem] = []
            for reference in matching {
                if let item = await resolve(
                    reference,
                    server: context.server,
                    records: records,
                    mayLoadRemote: mayLoadRemote
                ) {
                    result.append(item)
                }
            }
            try validate(context)
            ShelvIntentDiagnostics.entityLookupCompleted(
                requestedCount: references.count,
                matchingServerCount: matching.count,
                resultCount: result.count
            )
            return result
        } catch {
            ShelvIntentDiagnostics.entityLookupFailed(error: error)
            throw error
        }
    }

    private func activeContext() async throws -> (server: SubsonicServer, storageServerID: String) {
        let serverStore = ServerStore.shared
        await serverStore.waitUntilReady()
        guard let server = serverStore.activeServer else {
            throw ShortcutPlaybackError.noActiveServer
        }
        await DownloadDatabase.shared.setup()
        let storageID = server.stableId.isEmpty ? server.id.uuidString : server.stableId
        return (server, storageID)
    }

    private func networkAvailable() async -> Bool {
        guard !OfflineModeService.shared.isOffline else { return false }
        return await NetworkStatus.shared.waitUntilNetworkAvailable()
    }

    private func remoteSearchResults(for terms: [String]) async -> [SearchResult] {
        let api = self.api
        return await withTaskGroup(of: (Int, SearchResult?).self, returning: [SearchResult].self) { group in
            for (index, term) in terms.enumerated() {
                group.addTask {
                    let result: SearchResult? = await Self.valueBeforeDeadline(
                        named: "search"
                    ) {
                        try await api.search(query: term)
                    }
                    return (index, result)
                }
            }
            var values: [(Int, SearchResult)] = []
            for await (index, result) in group {
                if let result { values.append((index, result)) }
            }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func remoteStarred() async -> StarredResult? {
        let api = self.api
        return await Self.valueBeforeDeadline(named: "getStarred") {
            try await api.getStarred()
        }
    }

    private func remotePlaylists() async -> [Playlist] {
        let api = self.api
        return await Self.valueBeforeDeadline(named: "getPlaylists") {
            try await api.getPlaylists()
        } ?? []
    }

    private func remoteRecentSongs() async -> [Song] {
        let api = self.api
        return await Self.valueBeforeDeadline(named: "getRecentSongs") {
            try await api.getRecentSongs(albumCount: 12, limit: 12)
        } ?? []
    }

    private func remoteRadios() async -> [RadioStationDisplayItem] {
        RadioStationStore.shared.publishShortcutCacheIfNeeded()
        let refreshed: [RadioStationDisplayItem]? = await Self.valueBeforeDeadline(
            named: "refreshRadios"
        ) {
            await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            return await RadioStationStore.shared.items
        }
        return refreshed ?? RadioStationStore.shared.items
    }

    private nonisolated static func valueBeforeDeadline<Value: Sendable>(
        _ duration: Duration = .seconds(6),
        named operationName: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        await withTaskGroup(of: (value: Value?, timedOut: Bool).self, returning: Value?.self) { group in
            group.addTask {
                do {
                    return (try await operation(), false)
                } catch {
                    if !Task.isCancelled,
                       ShortcutPlaybackError.remoteFailure(error) != .cancelled {
                        ShelvIntentDiagnostics.catalogRemoteFailed(
                            operation: operationName,
                            error: error
                        )
                    }
                    return (nil, false)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: duration)
                    return (nil, true)
                } catch {
                    return (nil, false)
                }
            }
            let first = await group.next() ?? (nil, false)
            group.cancelAll()
            if first.timedOut {
                ShelvIntentDiagnostics.catalogRemoteTimedOut(operation: operationName)
            }
            return first.value
        }
    }

    private func validate(_ context: (server: SubsonicServer, storageServerID: String)) throws {
        guard ServerStore.shared.activeServer?.id == context.server.id else {
            throw ShortcutPlaybackError.serverChanged
        }
    }

    private func resolve(
        _ reference: ShortcutPlayableReference,
        server: SubsonicServer,
        records: [DownloadRecord],
        mayLoadRemote: Bool
    ) async -> ShelvIntentCatalogItem? {
        let api = self.api
        switch reference.kind {
        case .song:
            if let record = records.first(where: { $0.songId == reference.contentID }) {
                return songItem(record.toDownloadedSong().asSong(), server: server)
            }
            guard mayLoadRemote,
                  let song: Song = await Self.valueBeforeDeadline(named: "resolveSong", operation: {
                      try await api.getSong(id: reference.contentID)
                  })
            else { return nil }
            return songItem(song, server: server)

        case .album:
            let local = records.filter { $0.albumId == reference.contentID }
            if let first = local.first {
                return albumItem(local, first: first, server: server)
            }
            guard mayLoadRemote,
                  let album: AlbumDetail = await Self.valueBeforeDeadline(named: "resolveAlbum", operation: {
                      try await api.getAlbum(id: reference.contentID)
                  })
            else { return nil }
            return albumItem(album, server: server)

        case .artist:
            let local = records.filter { $0.artistId == reference.contentID }
            if let first = local.first {
                return artistItem(local, first: first, server: server)
            }
            guard mayLoadRemote,
                  let artist: ArtistDetail = await Self.valueBeforeDeadline(named: "resolveArtist", operation: {
                      try await api.getArtist(id: reference.contentID)
                  })
            else { return nil }
            return artistItem(artist, server: server)

        case .playlist:
            let localPlaylists = await LocalOfflinePlaylistCatalog.descriptors(
                serverId: server.stableId.isEmpty ? server.id.uuidString : server.stableId,
                serverConfigID: server.id
            )
            let availableSongIDs = Set(records.map(\.songId))
            let local = localPlaylists.first(where: {
                $0.id == reference.contentID
                    && $0.songIds.contains(where: availableSongIDs.contains)
            })
            if mayLoadRemote,
               let playlist: Playlist = await Self.valueBeforeDeadline(
                   named: "resolvePlaylist",
                   operation: { try await api.getPlaylist(id: reference.contentID) }
               ) {
                await LocalOfflinePlaylistCatalog.updateName(
                    serverId: server.stableId.isEmpty ? server.id.uuidString : server.stableId,
                    id: playlist.id,
                    name: playlist.name
                )
                return playlistItem(playlist, server: server)
            }
            if let local {
                return localPlaylistItem(local, records: records, server: server)
            }
            return nil

        case .radio:
            if RadioStationStore.shared.items.isEmpty, mayLoadRemote {
                await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            } else {
                RadioStationStore.shared.publishShortcutCacheIfNeeded()
            }
            guard let radio = RadioStationStore.shared.items.first(where: { $0.id == reference.contentID }) else {
                return nil
            }
            return radioItem(radio, server: server)
        }
    }

    private func localItems(for record: DownloadRecord, server: SubsonicServer) -> [ShelvIntentCatalogItem] {
        let song = songItem(record.toDownloadedSong().asSong(), server: server)
        var values = [song]
        if !record.albumId.isEmpty {
            values.append(albumItem([record], first: record, server: server))
        }
        if let artistID = record.artistId, !artistID.isEmpty {
            values.append(artistItem([record], first: record, server: server))
        }
        return values
    }

    private func localCollectionItems(
        from records: [DownloadRecord],
        server: SubsonicServer
    ) -> [ShelvIntentCatalogItem] {
        let albums = Dictionary(grouping: records.filter { !$0.albumId.isEmpty }, by: \.albumId)
            .values.compactMap { group in
                group.first.map { albumItem(group, first: $0, server: server) }
            }
        let artists = Dictionary(
            grouping: records.filter { !($0.artistId ?? "").isEmpty },
            by: { $0.artistId ?? "" }
        ).values.compactMap { group in
            group.first.map { artistItem(group, first: $0, server: server) }
        }
        return albums + artists
    }

    private func songItem(_ song: Song, server: SubsonicServer) -> ShelvIntentCatalogItem {
        ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .song, contentID: song.id),
            title: song.title,
            artistID: song.artistId,
            artistName: song.artist,
            albumID: song.albumId,
            albumTitle: song.album,
            duration: song.duration.map(TimeInterval.init),
            itemCount: nil,
            internationalStandardRecordingCode: song.isrc?.first
        )
    }

    private func albumItem(_ album: Album, server: SubsonicServer) -> ShelvIntentCatalogItem {
        ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .album, contentID: album.id),
            title: album.name,
            artistID: album.artistId,
            artistName: album.artist,
            albumID: album.id,
            albumTitle: album.name,
            duration: album.duration.map(TimeInterval.init),
            itemCount: album.songCount,
            internationalStandardRecordingCode: nil
        )
    }

    private func albumItem(from song: Song, server: SubsonicServer) -> ShelvIntentCatalogItem? {
        guard let id = song.albumId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              let title = song.album?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .album, contentID: id),
            title: title,
            artistID: song.artistId,
            artistName: song.artist,
            albumID: id,
            albumTitle: title,
            duration: nil,
            itemCount: nil,
            internationalStandardRecordingCode: nil
        )
    }

    private func albumItem(_ album: AlbumDetail, server: SubsonicServer) -> ShelvIntentCatalogItem {
        ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .album, contentID: album.id),
            title: album.name,
            artistID: album.artistId,
            artistName: album.artist,
            albumID: album.id,
            albumTitle: album.name,
            duration: album.duration.map(TimeInterval.init),
            itemCount: album.songCount,
            internationalStandardRecordingCode: nil
        )
    }

    private func albumItem(
        _ records: [DownloadRecord],
        first: DownloadRecord,
        server: SubsonicServer
    ) -> ShelvIntentCatalogItem {
        ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .album, contentID: first.albumId),
            title: first.albumTitle,
            artistID: first.artistId,
            artistName: first.albumArtistName ?? first.artistName,
            albumID: first.albumId,
            albumTitle: first.albumTitle,
            duration: TimeInterval(records.reduce(0) { $0 + ($1.duration ?? 0) }),
            itemCount: records.count,
            internationalStandardRecordingCode: nil
        )
    }

    private func artistItem(_ artist: Artist, server: SubsonicServer) -> ShelvIntentCatalogItem {
        ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .artist, contentID: artist.id),
            title: artist.name,
            artistID: artist.id,
            artistName: artist.name,
            albumID: nil,
            albumTitle: nil,
            duration: nil,
            itemCount: artist.albumCount,
            internationalStandardRecordingCode: nil
        )
    }

    private func artistItem(from song: Song, server: SubsonicServer) -> ShelvIntentCatalogItem? {
        guard let id = song.artistId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              let name = song.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .artist, contentID: id),
            title: name,
            artistID: id,
            artistName: name,
            albumID: nil,
            albumTitle: nil,
            duration: nil,
            itemCount: nil,
            internationalStandardRecordingCode: nil
        )
    }

    private func artistItem(_ artist: ArtistDetail, server: SubsonicServer) -> ShelvIntentCatalogItem {
        ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .artist, contentID: artist.id),
            title: artist.name,
            artistID: artist.id,
            artistName: artist.name,
            albumID: nil,
            albumTitle: nil,
            duration: nil,
            itemCount: artist.albumCount,
            internationalStandardRecordingCode: nil
        )
    }

    private func artistItem(
        _ records: [DownloadRecord],
        first: DownloadRecord,
        server: SubsonicServer
    ) -> ShelvIntentCatalogItem {
        let albumCount = Set(records.map(\.albumId).filter { !$0.isEmpty }).count
        return ShelvIntentCatalogItem(
            reference: .init(
                serverConfigID: server.id.uuidString,
                kind: .artist,
                contentID: first.artistId ?? first.artistName
            ),
            title: first.artistName,
            artistID: first.artistId,
            artistName: first.artistName,
            albumID: nil,
            albumTitle: nil,
            duration: nil,
            itemCount: albumCount,
            internationalStandardRecordingCode: nil
        )
    }

    private func playlistItem(_ playlist: Playlist, server: SubsonicServer) -> ShelvIntentCatalogItem {
        ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .playlist, contentID: playlist.id),
            title: playlist.name,
            artistID: nil,
            artistName: nil,
            albumID: nil,
            albumTitle: nil,
            duration: playlist.duration.map(TimeInterval.init),
            itemCount: playlist.songCount,
            internationalStandardRecordingCode: nil
        )
    }

    private func localPlaylistItem(
        _ playlist: OfflinePlaylistDescriptor,
        records: [DownloadRecord],
        server: SubsonicServer
    ) -> ShelvIntentCatalogItem {
        let availableIDs = Set(records.map(\.songId))
        let count = playlist.songIds.filter(availableIDs.contains).count
        return ShelvIntentCatalogItem(
            reference: .init(
                serverConfigID: server.id.uuidString,
                kind: .playlist,
                contentID: playlist.id
            ),
            title: playlist.name ?? String(localized: "shortcut_kind_playlist"),
            artistID: nil,
            artistName: nil,
            albumID: nil,
            albumTitle: nil,
            duration: nil,
            itemCount: count,
            internationalStandardRecordingCode: nil
        )
    }

    private func radioItem(
        _ radio: RadioStationDisplayItem,
        server: SubsonicServer
    ) -> ShelvIntentCatalogItem {
        ShelvIntentCatalogItem(
            reference: .init(serverConfigID: server.id.uuidString, kind: .radio, contentID: radio.id),
            title: radio.name,
            artistID: nil,
            artistName: nil,
            albumID: nil,
            albumTitle: nil,
            duration: nil,
            itemCount: nil,
            internationalStandardRecordingCode: nil
        )
    }

    private func merge(
        _ item: ShelvIntentCatalogItem,
        query: String,
        into values: inout [ShortcutPlayableReference: (item: ShelvIntentCatalogItem, score: Int)]
    ) {
        guard let score = relevance(of: item, for: query) else { return }
        if let current = values[item.reference], current.score >= score { return }
        values[item.reference] = (item, score)
    }

    private func relevance(of item: ShelvIntentCatalogItem, for query: String) -> Int? {
        ShelvIntentSearchRanking.relevantScore(
            kind: item.reference.kind,
            title: item.title,
            artistName: item.artistName,
            albumTitle: item.albumTitle,
            query: query
        )
    }

    private func matches(_ value: String, query: String, terms: [String]) -> Bool {
        let normalizedValue = ShelvIntentSearchVocabulary.normalized(value)
        if normalizedValue.contains(ShelvIntentSearchVocabulary.normalized(query)) { return true }
        return terms.contains { normalizedValue.contains(ShelvIntentSearchVocabulary.normalized($0)) }
    }

    private func balancedUnique(
        _ items: [ShelvIntentCatalogItem],
        allowedKinds: Set<ShortcutPlayableKind>,
        limit: Int
    ) -> [ShelvIntentCatalogItem] {
        guard limit > 0 else { return [] }
        let kinds = ShortcutPlayableKind.allCases.filter(allowedKinds.contains)
        var buckets = Dictionary(grouping: items.filter {
            allowedKinds.contains($0.reference.kind)
        }, by: { $0.reference.kind })
        var seen = Set<ShortcutPlayableReference>()
        for kind in kinds {
            guard let bucket = buckets[kind] else { continue }
            var positions: [ShortcutPlayableReference: Int] = [:]
            var uniqueBucket: [ShelvIntentCatalogItem] = []
            for item in bucket {
                if let index = positions[item.reference] {
                    uniqueBucket[index] = item
                } else {
                    positions[item.reference] = uniqueBucket.count
                    uniqueBucket.append(item)
                }
            }
            buckets[kind] = uniqueBucket.filter { seen.insert($0.reference).inserted }
        }

        var indices = Dictionary(uniqueKeysWithValues: kinds.map { ($0, 0) })
        var result: [ShelvIntentCatalogItem] = []
        while result.count < limit {
            var appended = false
            for kind in kinds where result.count < limit {
                let index = indices[kind, default: 0]
                guard let bucket = buckets[kind], index < bucket.count else { continue }
                result.append(bucket[index])
                indices[kind] = index + 1
                appended = true
            }
            if !appended { break }
        }
        return result
    }
}
