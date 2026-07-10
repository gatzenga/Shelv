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

    func suggestedItems(limit: Int = 40) async throws -> [ShelvIntentCatalogItem] {
        let context = try await activeContext()
        let records = await DownloadDatabase.shared.allRecords(serverId: context.storageServerID)
        var items = records.prefix(8).map { songItem($0.toDownloadedSong().asSong(), server: context.server) }

        guard await networkAvailable() else {
            items += localCollectionItems(from: records, server: context.server)
            try validate(context)
            return unique(items, limit: limit)
        }

        async let starredResult = try? api.getStarred()
        async let playlistsResult = try? api.getPlaylists()
        async let recentResult = try? api.getRecentSongs(albumCount: 12, limit: 12)
        async let radioRefresh: Void = RadioStationStore.shared.refresh(waitForCloudMetadata: false)

        let (starred, playlists, recent, _) = await (
            starredResult,
            playlistsResult,
            recentResult,
            radioRefresh
        )

        if let starred {
            items += (starred.song ?? []).prefix(8).map { songItem($0, server: context.server) }
            items += (starred.album ?? []).prefix(6).map { albumItem($0, server: context.server) }
            items += (starred.artist ?? []).prefix(6).map { artistItem($0, server: context.server) }
        }
        items += (playlists ?? []).prefix(8).map { playlistItem($0, server: context.server) }
        items += (recent ?? []).prefix(8).map { songItem($0, server: context.server) }
        items += RadioStationStore.shared.items.prefix(6).map { radioItem($0, server: context.server) }
        try validate(context)
        return unique(items, limit: limit)
    }

    func items(matching rawQuery: String, limit: Int = 60) async throws -> [ShelvIntentCatalogItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedItems(limit: limit) }

        let context = try await activeContext()
        let terms = ShelvIntentSearchVocabulary.searchTerms(for: query)
        var scored: [ShortcutPlayableReference: (item: ShelvIntentCatalogItem, score: Int)] = [:]

        for term in terms {
            let records = await DownloadDatabase.shared.search(
                serverId: context.storageServerID,
                query: term,
                limit: 60
            )
            for item in records.flatMap({ localItems(for: $0, server: context.server) }) {
                merge(item, query: query, into: &scored)
            }
        }

        if await networkAvailable() {
            let api = self.api
            let results = await withTaskGroup(of: SearchResult?.self, returning: [SearchResult].self) { group in
                for term in terms {
                    group.addTask { try? await api.search(query: term) }
                }
                var values: [SearchResult] = []
                for await result in group {
                    if let result { values.append(result) }
                }
                return values
            }

            for result in results {
                for song in result.song ?? [] {
                    merge(songItem(song, server: context.server), query: query, into: &scored)
                }
                for album in result.album ?? [] {
                    merge(albumItem(album, server: context.server), query: query, into: &scored)
                }
                for artist in result.artist ?? [] {
                    merge(artistItem(artist, server: context.server), query: query, into: &scored)
                }
            }

            async let playlistsResult = try? api.getPlaylists()
            async let radioRefresh: Void = RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            let (playlists, _) = await (playlistsResult, radioRefresh)
            for playlist in playlists ?? [] where matches(playlist.name, query: query, terms: terms) {
                merge(playlistItem(playlist, server: context.server), query: query, into: &scored)
            }
            for radio in RadioStationStore.shared.items where matches(radio.name, query: query, terms: terms) {
                merge(radioItem(radio, server: context.server), query: query, into: &scored)
            }
        }

        try validate(context)
        return scored.values
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                let titleOrder = $0.item.title.localizedStandardCompare($1.item.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return $0.item.reference.kind.rawValue < $1.item.reference.kind.rawValue
            }
            .prefix(limit)
            .map(\.item)
    }

    func items(for identifiers: [String]) async throws -> [ShelvIntentCatalogItem] {
        let references = identifiers.compactMap(ShortcutPlayableReference.init(identifier:))
        return try await items(for: references)
    }

    func items(for references: [ShortcutPlayableReference]) async throws -> [ShelvIntentCatalogItem] {
        let context = try await activeContext()
        let matching = references.filter { $0.serverConfigID == context.server.id.uuidString }
        guard !matching.isEmpty else { return [] }
        let records = await DownloadDatabase.shared.allRecords(serverId: context.storageServerID)
        let hasNetwork = await networkAvailable()

        var result: [ShelvIntentCatalogItem] = []
        for reference in matching {
            if let item = await resolve(
                reference,
                server: context.server,
                records: records,
                hasNetwork: hasNetwork
            ) {
                result.append(item)
            }
        }
        try validate(context)
        return result
    }

    private func activeContext() async throws -> (server: SubsonicServer, storageServerID: String) {
        _ = ServerStore.shared
        guard let server = ServerStore.shared.activeServer else {
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

    private func validate(_ context: (server: SubsonicServer, storageServerID: String)) throws {
        guard ServerStore.shared.activeServer?.id == context.server.id else {
            throw ShortcutPlaybackError.serverChanged
        }
    }

    private func resolve(
        _ reference: ShortcutPlayableReference,
        server: SubsonicServer,
        records: [DownloadRecord],
        hasNetwork: Bool
    ) async -> ShelvIntentCatalogItem? {
        switch reference.kind {
        case .song:
            if let record = records.first(where: { $0.songId == reference.contentID }) {
                return songItem(record.toDownloadedSong().asSong(), server: server)
            }
            guard hasNetwork, let song = try? await api.getSong(id: reference.contentID) else { return nil }
            return songItem(song, server: server)

        case .album:
            let local = records.filter { $0.albumId == reference.contentID }
            if let first = local.first {
                return albumItem(local, first: first, server: server)
            }
            guard hasNetwork, let album = try? await api.getAlbum(id: reference.contentID) else { return nil }
            return albumItem(album, server: server)

        case .artist:
            let local = records.filter { $0.artistId == reference.contentID }
            if let first = local.first {
                return artistItem(local, first: first, server: server)
            }
            guard hasNetwork, let artist = try? await api.getArtist(id: reference.contentID) else { return nil }
            return artistItem(artist, server: server)

        case .playlist:
            guard hasNetwork, let playlist = try? await api.getPlaylist(id: reference.contentID) else { return nil }
            return playlistItem(playlist, server: server)

        case .radio:
            if RadioStationStore.shared.items.isEmpty, hasNetwork {
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
        let score = relevance(of: item, for: query)
        if let current = values[item.reference], current.score >= score { return }
        values[item.reference] = (item, score)
    }

    private func relevance(of item: ShelvIntentCatalogItem, for query: String) -> Int {
        let normalizedQuery = ShelvIntentSearchVocabulary.normalized(query)
        let fields = [item.title, item.artistName, item.albumTitle]
            .compactMap { $0 }
            .map(ShelvIntentSearchVocabulary.normalized)
        let queryWords = Set(normalizedQuery.split(separator: " ").map(String.init))
        var score = 0
        for field in fields {
            if field == normalizedQuery { score += 120 }
            else if field.contains(normalizedQuery) { score += 60 }
            let words = Set(field.split(separator: " ").map(String.init))
            score += queryWords.intersection(words).count * 12
        }

        let lowered = query.lowercased()
        switch item.reference.kind {
        case .song where lowered.contains("song") || lowered.contains("track") || lowered.contains("titel"):
            score += 35
        case .album where lowered.contains("album"):
            score += 35
        case .artist where lowered.contains("artist") || lowered.contains("künstler") || lowered.contains(" by ") || lowered.contains(" von "):
            score += 25
        case .playlist where lowered.contains("playlist"):
            score += 35
        case .radio where lowered.contains("radio") || lowered.contains("station") || lowered.contains("sender"):
            score += 35
        default:
            break
        }
        return score
    }

    private func matches(_ value: String, query: String, terms: [String]) -> Bool {
        let normalizedValue = ShelvIntentSearchVocabulary.normalized(value)
        if normalizedValue.contains(ShelvIntentSearchVocabulary.normalized(query)) { return true }
        return terms.contains { normalizedValue.contains(ShelvIntentSearchVocabulary.normalized($0)) }
    }

    private func unique(
        _ items: [ShelvIntentCatalogItem],
        limit: Int
    ) -> [ShelvIntentCatalogItem] {
        var seen = Set<ShortcutPlayableReference>()
        return Array(items.filter { seen.insert($0.reference).inserted }.prefix(limit))
    }
}
