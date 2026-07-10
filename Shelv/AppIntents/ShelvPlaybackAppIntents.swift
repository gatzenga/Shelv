import AppIntents
import Foundation

nonisolated extension ShortcutPlaybackOrder: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "shortcut_order_type"
    }

    static var caseDisplayRepresentations: [ShortcutPlaybackOrder: DisplayRepresentation] {
        [
            .inOrder: "shortcut_order_in_order",
            .shuffled: "shortcut_order_shuffled",
        ]
    }
}

nonisolated extension ShortcutSmartMix: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "shortcut_mix_type"
    }

    static var caseDisplayRepresentations: [ShortcutSmartMix: DisplayRepresentation] {
        [
            .newest: "shortcut_mix_newest",
            .frequent: "shortcut_mix_frequent",
            .recent: "shortcut_mix_recent",
            .shuffleAll: "shortcut_shuffle_all",
        ]
    }
}

nonisolated extension ShortcutDownloadsMode: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "shortcut_downloads_type"
    }

    static var caseDisplayRepresentations: [ShortcutDownloadsMode: DisplayRepresentation] {
        [
            .all: "shortcut_downloads_all",
            .shuffled: "shortcut_downloads_shuffled",
            .newest: "shortcut_downloads_newest",
        ]
    }
}

struct ShelvPlayableEntity: AppEntity, Identifiable, Hashable, Sendable {
    let serverConfigID: String
    let kind: ShortcutPlayableKind
    let contentID: String
    let name: String
    let detail: String?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_playable_type"
    static let defaultQuery = ShelvPlayableQuery()

    var id: String {
        let encodedID = Data(contentID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(serverConfigID)|\(kind.rawValue)|\(encodedID)"
    }

    var displayRepresentation: DisplayRepresentation {
        let kindName = String(localized: kind.localizedName)
        let subtitle = [detail, kindName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }

    var reference: ShortcutPlayableReference {
        ShortcutPlayableReference(
            serverConfigID: serverConfigID,
            kind: kind,
            contentID: contentID
        )
    }

    fileprivate static func parse(identifier: String) -> (String, ShortcutPlayableKind, String)? {
        let components = identifier.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 3,
              let kind = ShortcutPlayableKind(rawValue: String(components[1]))
        else { return nil }

        var encoded = String(components[2])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 { encoded += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: encoded),
              let contentID = String(data: data, encoding: .utf8)
        else { return nil }
        return (String(components[0]), kind, contentID)
    }
}

private extension ShortcutPlayableKind {
    var localizedName: LocalizedStringResource {
        switch self {
        case .song: return "shortcut_kind_song"
        case .album: return "shortcut_kind_album"
        case .artist: return "shortcut_kind_artist"
        case .playlist: return "shortcut_kind_playlist"
        case .radio: return "shortcut_kind_radio"
        }
    }
}

struct ShelvPlayableQuery: EntityStringQuery {
    @MainActor private static var lastPlaylistRefresh: [String: Date] = [:]
    @MainActor private static var lastRadioRefresh: [String: Date] = [:]
    private let allowedKinds: Set<ShortcutPlayableKind>

    init() {
        allowedKinds = Set(ShortcutPlayableKind.allCases)
    }

    init(allowedKinds: Set<ShortcutPlayableKind>) {
        self.allowedKinds = allowedKinds
    }

    func entities(for identifiers: [ShelvPlayableEntity.ID]) async throws -> [ShelvPlayableEntity] {
        guard let server = await activeServer() else { return [] }
        await publishShortcutCaches()
        var entities: [ShelvPlayableEntity] = []
        for identifier in identifiers {
            guard let parsed = ShelvPlayableEntity.parse(identifier: identifier),
                  parsed.0 == server.id.uuidString,
                  allowedKinds.contains(parsed.1),
                  let entity = await entity(kind: parsed.1, contentID: parsed.2, server: server)
            else { continue }
            entities.append(entity)
        }
        return entities
    }

    func suggestedEntities() async throws -> [ShelvPlayableEntity] {
        guard let server = await activeServer() else { return [] }
        let store = await MainActor.run { LibraryStore.shared }
        await publishShortcutCaches()

        var result = await MainActor.run {
            let downloadedSongs = allowedKinds.contains(.song) ? DownloadStore.shared.songs.prefix(6).map {
                makeSong($0.asSong(), server: server)
            } : []
            let downloadedAlbums = allowedKinds.contains(.album) ? DownloadStore.shared.albums.prefix(6).map {
                makeAlbum($0.asAlbum(), server: server)
            } : []
            let downloadedArtists = allowedKinds.contains(.artist) ? DownloadStore.shared.artists.prefix(4).map {
                makeArtist($0.asArtist(), server: server)
            } : []
            let playlists = allowedKinds.contains(.playlist)
                ? store.playlists.prefix(8).map { makePlaylist($0, server: server) }
                : []
            let recentAlbums = allowedKinds.contains(.album)
                ? store.recentlyPlayed.prefix(6).map { makeAlbum($0, server: server) }
                : []
            let starredSongs = allowedKinds.contains(.song)
                ? store.starredSongs.prefix(6).map { makeSong($0, server: server) }
                : []
            let starredAlbums = allowedKinds.contains(.album)
                ? store.starredAlbums.prefix(4).map { makeAlbum($0, server: server) }
                : []
            let starredArtists = allowedKinds.contains(.artist)
                ? store.starredArtists.prefix(4).map { makeArtist($0, server: server) }
                : []
            return downloadedSongs + downloadedAlbums + downloadedArtists + playlists
                + recentAlbums + starredSongs + starredAlbums + starredArtists
        }

        if allowedKinds.contains(.radio) {
            result += await MainActor.run {
                RadioStationStore.shared.items.prefix(6).map { makeRadio($0, server: server) }
            }
        }
        return unique(result, limit: 30)
    }

    func entities(matching string: String) async throws -> [ShelvPlayableEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        guard let server = await activeServer() else { return [] }
        await publishShortcutCaches()

        let isOffline = await MainActor.run { OfflineModeService.shared.isOffline }
        let hasNetwork: Bool
        if isOffline {
            hasNetwork = false
        } else {
            hasNetwork = await NetworkStatus.shared.waitUntilNetworkAvailable()
        }
        async let collectionRefresh: Void = refreshCollectionsForSearch(
            hasNetwork: hasNetwork,
            serverConfigID: server.id.uuidString
        )
        async let remoteSearch = searchServer(query: query, hasNetwork: hasNetwork)

        await collectionRefresh
        var result = await localEntities(matching: query, server: server)
        if let search = await remoteSearch {
            if allowedKinds.contains(.song) {
                result += (search.song ?? []).map { makeSong($0, server: server) }
            }
            if allowedKinds.contains(.album) {
                result += (search.album ?? []).map { makeAlbum($0, server: server) }
            }
            if allowedKinds.contains(.artist) {
                result += (search.artist ?? []).map { makeArtist($0, server: server) }
            }
        }
        guard await MainActor.run(body: {
            ServerStore.shared.activeServer?.id == server.id
        }) else { return [] }
        return unique(result, limit: 40)
    }

    private func publishShortcutCaches() async {
        async let libraryCache: Void = LibraryStore.shared.loadShortcutCaches()
        async let radioCache: Void = MainActor.run {
            RadioStationStore.shared.publishShortcutCacheIfNeeded()
        }
        _ = await (libraryCache, radioCache)
    }

    private func refreshCollectionsForSearch(
        hasNetwork: Bool,
        serverConfigID: String
    ) async {
        guard hasNetwork else { return }
        let needs = await MainActor.run { () -> (playlists: Bool, radio: Bool) in
            let now = Date()
            let playlists = allowedKinds.contains(.playlist)
                && now.timeIntervalSince(Self.lastPlaylistRefresh[serverConfigID] ?? .distantPast) >= 30
            let radio = allowedKinds.contains(.radio)
                && now.timeIntervalSince(Self.lastRadioRefresh[serverConfigID] ?? .distantPast) >= 30
            if playlists {
                Self.lastPlaylistRefresh[serverConfigID] = now
            }
            if radio {
                Self.lastRadioRefresh[serverConfigID] = now
            }
            return (playlists, radio)
        }
        await withTaskGroup(of: Void.self) { group in
            if needs.playlists {
                group.addTask { await LibraryStore.shared.loadPlaylists() }
            }
            if needs.radio {
                group.addTask {
                    await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
                }
            }
        }
    }

    private func searchServer(query: String, hasNetwork: Bool) async -> SearchResult? {
        guard hasNetwork,
              !allowedKinds.isDisjoint(with: [.song, .album, .artist])
        else { return nil }
        return try? await SubsonicAPIService.shared.search(query: query)
    }

    @MainActor
    private func activeServer() async -> SubsonicServer? {
        _ = ServerStore.shared
        guard let server = ServerStore.shared.activeServer else { return nil }
        await DownloadDatabase.shared.setup()
        let storageServerID = server.stableId.isEmpty ? server.id.uuidString : server.stableId
        await DownloadStore.shared.setActiveServer(storageServerID)
        return server
    }

    @MainActor
    private func localEntities(matching query: String, server: SubsonicServer) -> [ShelvPlayableEntity] {
        let matches: (String) -> Bool = {
            $0.localizedStandardContains(query)
        }
        let downloads = DownloadStore.shared
        let library = LibraryStore.shared
        let songs = allowedKinds.contains(.song) ? downloads.songs.filter {
            matches($0.title) || matches($0.artistName) || matches($0.albumTitle)
        }.prefix(15).map { makeSong($0.asSong(), server: server) } : []
        let albums = allowedKinds.contains(.album) ? downloads.albums.filter {
            matches($0.title) || matches($0.artistName)
        }.prefix(10).map { makeAlbum($0.asAlbum(), server: server) } : []
        let artists = allowedKinds.contains(.artist)
            ? downloads.artists.filter { matches($0.name) }
                .prefix(10).map { makeArtist($0.asArtist(), server: server) }
            : []
        let playlists = allowedKinds.contains(.playlist)
            ? library.playlists.filter { matches($0.name) }
                .prefix(10).map { makePlaylist($0, server: server) }
            : []
        let radios = allowedKinds.contains(.radio)
            ? RadioStationStore.shared.items.filter { matches($0.name) }
                .prefix(10).map { makeRadio($0, server: server) }
            : []
        return songs + albums + artists + playlists + radios
    }

    private func entity(
        kind: ShortcutPlayableKind,
        contentID: String,
        server: SubsonicServer
    ) async -> ShelvPlayableEntity? {
        guard allowedKinds.contains(kind) else { return nil }
        let isOffline = await MainActor.run { OfflineModeService.shared.isOffline }
        if let local = await localEntity(kind: kind, contentID: contentID, server: server) {
            return local
        }
        guard !isOffline,
              await NetworkStatus.shared.waitUntilNetworkAvailable()
        else { return nil }

        switch kind {
        case .song:
            return (try? await SubsonicAPIService.shared.getSong(id: contentID))
                .map { makeSong($0, server: server) }
        case .album:
            guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: contentID) else { return nil }
            return ShelvPlayableEntity(
                serverConfigID: server.id.uuidString,
                kind: .album,
                contentID: detail.id,
                name: detail.name,
                detail: detail.artist
            )
        case .artist:
            guard let detail = try? await SubsonicAPIService.shared.getArtist(id: contentID) else { return nil }
            return ShelvPlayableEntity(
                serverConfigID: server.id.uuidString,
                kind: .artist,
                contentID: detail.id,
                name: detail.name,
                detail: nil
            )
        case .playlist:
            if await MainActor.run(body: { LibraryStore.shared.playlists.isEmpty }) {
                await LibraryStore.shared.loadPlaylists()
            }
            return await MainActor.run {
                LibraryStore.shared.playlists.first { $0.id == contentID }
                    .map { makePlaylist($0, server: server) }
            }
        case .radio:
            if await MainActor.run(body: { RadioStationStore.shared.items.isEmpty }) {
                await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            }
            return await MainActor.run {
                RadioStationStore.shared.items.first { $0.id == contentID }
                    .map { makeRadio($0, server: server) }
            }
        }
    }

    @MainActor
    private func localEntity(
        kind: ShortcutPlayableKind,
        contentID: String,
        server: SubsonicServer
    ) -> ShelvPlayableEntity? {
        switch kind {
        case .song:
            return DownloadStore.shared.songs.first { $0.songId == contentID }
                .map { makeSong($0.asSong(), server: server) }
        case .album:
            return DownloadStore.shared.albums.first { $0.albumId == contentID }
                .map { makeAlbum($0.asAlbum(), server: server) }
        case .artist:
            return DownloadStore.shared.artists.first { $0.artistId == contentID }
                .map { makeArtist($0.asArtist(), server: server) }
        case .playlist:
            return LibraryStore.shared.playlists.first { $0.id == contentID }
                .map { makePlaylist($0, server: server) }
        case .radio:
            return RadioStationStore.shared.items.first { $0.id == contentID }
                .map { makeRadio($0, server: server) }
        }
    }

    private func unique(_ entities: [ShelvPlayableEntity], limit: Int) -> [ShelvPlayableEntity] {
        var seen = Set<ShelvPlayableEntity.ID>()
        return Array(entities.filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    private func makeSong(_ song: Song, server: SubsonicServer) -> ShelvPlayableEntity {
        ShelvPlayableEntity(
            serverConfigID: server.id.uuidString,
            kind: .song,
            contentID: song.id,
            name: song.title,
            detail: song.artist
        )
    }

    private func makeAlbum(_ album: Album, server: SubsonicServer) -> ShelvPlayableEntity {
        ShelvPlayableEntity(
            serverConfigID: server.id.uuidString,
            kind: .album,
            contentID: album.id,
            name: album.name,
            detail: album.artist
        )
    }

    private func makeArtist(_ artist: Artist, server: SubsonicServer) -> ShelvPlayableEntity {
        ShelvPlayableEntity(
            serverConfigID: server.id.uuidString,
            kind: .artist,
            contentID: artist.id,
            name: artist.name,
            detail: nil
        )
    }

    private func makePlaylist(_ playlist: Playlist, server: SubsonicServer) -> ShelvPlayableEntity {
        ShelvPlayableEntity(
            serverConfigID: server.id.uuidString,
            kind: .playlist,
            contentID: playlist.id,
            name: playlist.name,
            detail: playlist.songCount.map {
                String(format: String(localized: "shortcut_track_count_format"), $0)
            }
        )
    }

    private func makeRadio(_ radio: RadioStationDisplayItem, server: SubsonicServer) -> ShelvPlayableEntity {
        ShelvPlayableEntity(
            serverConfigID: server.id.uuidString,
            kind: .radio,
            contentID: radio.id,
            name: radio.name,
            detail: nil
        )
    }
}

/// Restricts Instant Mix to the three source kinds the underlying mix service
/// supports. Using a dedicated entity keeps playlists and radio stations out of
/// both Siri resolution and the Shortcuts parameter picker.
struct ShelvInstantMixEntity: AppEntity, Identifiable, Hashable, Sendable {
    let playable: ShelvPlayableEntity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_instant_mix_type"
    static let defaultQuery = ShelvInstantMixQuery()

    var id: String { playable.id }
    var displayRepresentation: DisplayRepresentation { playable.displayRepresentation }
    var reference: ShortcutPlayableReference { playable.reference }
}

struct ShelvInstantMixQuery: EntityStringQuery {
    private let playableQuery = ShelvPlayableQuery(allowedKinds: [.song, .album, .artist])

    func entities(for identifiers: [ShelvInstantMixEntity.ID]) async throws -> [ShelvInstantMixEntity] {
        try await playableQuery.entities(for: identifiers).compactMap(Self.wrap)
    }

    func suggestedEntities() async throws -> [ShelvInstantMixEntity] {
        try await playableQuery.suggestedEntities().compactMap(Self.wrap)
    }

    func entities(matching string: String) async throws -> [ShelvInstantMixEntity] {
        try await playableQuery.entities(matching: string).compactMap(Self.wrap)
    }

    private static func wrap(_ playable: ShelvPlayableEntity) -> ShelvInstantMixEntity? {
        switch playable.kind {
        case .song, .album, .artist:
            return ShelvInstantMixEntity(playable: playable)
        case .playlist, .radio:
            return nil
        }
    }
}

private protocol ShelvBackgroundPlaybackIntent: AppIntent, AudioPlaybackIntent {}

extension ShelvBackgroundPlaybackIntent {
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
}

struct ShelvShuffleAllIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_shuffle_all_title"
    static let description = IntentDescription("shortcut_shuffle_all_description")

    @Dependency private var playback: ShortcutPlaybackCoordinator

    func perform() async throws -> some IntentResult {
        try await playback.execute(.mix(.shuffleAll))
        return .result()
    }
}

struct ShelvPlayPlayableIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_title"
    static let description = IntentDescription("shortcut_play_description")

    @Parameter(title: "shortcut_playable_parameter")
    var playable: ShelvPlayableEntity

    @Parameter(title: "shortcut_order_parameter", default: .inOrder)
    var order: ShortcutPlaybackOrder

    @Dependency private var playback: ShortcutPlaybackCoordinator

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_play_summary") {
            \.$playable
            \.$order
        }
    }

    func perform() async throws -> some IntentResult {
        try await playback.execute(.playable(playable.reference, order: order))
        return .result()
    }
}

struct ShelvPlayMixIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_mix_title"
    static let description = IntentDescription("shortcut_play_mix_description")

    @Parameter(title: "shortcut_mix_parameter", default: .shuffleAll)
    var mix: ShortcutSmartMix

    @Dependency private var playback: ShortcutPlaybackCoordinator

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_play_mix_summary") {
            \.$mix
        }
    }

    func perform() async throws -> some IntentResult {
        try await playback.execute(.mix(mix))
        return .result()
    }
}

struct ShelvPlayDownloadsIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_downloads_title"
    static let description = IntentDescription("shortcut_play_downloads_description")

    @Parameter(title: "shortcut_downloads_parameter", default: .shuffled)
    var mode: ShortcutDownloadsMode

    @Dependency private var playback: ShortcutPlaybackCoordinator

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_play_downloads_summary") {
            \.$mode
        }
    }

    func perform() async throws -> some IntentResult {
        try await playback.execute(.downloads(mode))
        return .result()
    }
}

struct ShelvInstantMixIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_instant_mix_title"
    static let description = IntentDescription("shortcut_instant_mix_description")

    @Parameter(title: "shortcut_instant_mix_parameter")
    var playable: ShelvInstantMixEntity

    @Dependency private var playback: ShortcutPlaybackCoordinator

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_instant_mix_summary") {
            \.$playable
        }
    }

    func perform() async throws -> some IntentResult {
        try await playback.execute(.instantMix(playable.reference))
        return .result()
    }
}
