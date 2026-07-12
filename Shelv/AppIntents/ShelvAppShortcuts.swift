import AppIntents
import Foundation

struct ShelvPlaylistEntity: AppEntity, Identifiable {
    let id: String
    let name: String
    let songCount: Int?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_playlist_type"
    static let defaultQuery = ShelvPlaylistQuery()

    var displayRepresentation: DisplayRepresentation {
        if let songCount {
            DisplayRepresentation(
                title: "\(name)",
                subtitle: "\(String(format: String(localized: "shortcut_track_count_format"), songCount))"
            )
        } else {
            DisplayRepresentation(title: "\(name)")
        }
    }
}

struct ShelvPlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvPlaylistEntity.ID]) async throws -> [ShelvPlaylistEntity] {
        let playlists = await fetchPlaylists()
        let requested = Set(identifiers)
        return playlists.filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ShelvPlaylistEntity] {
        Array(await fetchPlaylists().prefix(25))
    }

    func entities(matching string: String) async throws -> [ShelvPlaylistEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return await fetchPlaylists().filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    @MainActor
    private func fetchPlaylists() async -> [ShelvPlaylistEntity] {
        if SubsonicAPIService.shared.activeServer == nil {
            _ = ServerStore.shared
        }
        let store = LibraryStore.shared
        await store.loadShortcutCaches()
        let hasCachedPlaylists = !store.playlists.isEmpty
        let canRefresh: Bool
        if OfflineModeService.shared.isOffline {
            canRefresh = false
        } else {
            canRefresh = await NetworkStatus.shared.waitUntilNetworkAvailable()
        }
        if !hasCachedPlaylists, canRefresh {
            await store.loadPlaylists()
        } else if hasCachedPlaylists, canRefresh {
            Task { @MainActor in
                await store.loadPlaylists()
                ShelvAppShortcuts.updateAppShortcutParameters()
            }
        }
        let playlists = store.playlists
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map {
                ShelvPlaylistEntity(id: $0.id, name: $0.name, songCount: $0.songCount)
            }
        print("[Shortcuts] Playlists available → \(playlists.count)")
        return playlists
    }
}

struct ShelvPlayPauseIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_pause_title"
    static let description = IntentDescription("shortcut_play_pause_description")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .background

    @Dependency private var playback: ShortcutPlaybackCoordinator

    func perform() async throws -> some IntentResult {
        try await playback.execute(.playPause)
        return .result()
    }
}

struct ShelvNextTrackIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_next_title"
    static let description = IntentDescription("shortcut_next_description")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .background

    @Dependency private var playback: ShortcutPlaybackCoordinator

    func perform() async throws -> some IntentResult {
        try await playback.execute(.next)
        return .result()
    }
}

struct ShelvPreviousTrackIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_previous_title"
    static let description = IntentDescription("shortcut_previous_description")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .background

    @Dependency private var playback: ShortcutPlaybackCoordinator

    func perform() async throws -> some IntentResult {
        try await playback.execute(.previous)
        return .result()
    }
}

struct ShelvPlayPlaylistIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_playlist_title"
    static let description = IntentDescription("shortcut_play_playlist_description")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .background

    @Parameter(title: "shortcut_playlist_parameter")
    var playlist: ShelvPlaylistEntity

    @Dependency private var playback: ShortcutPlaybackCoordinator

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_play_playlist_summary") {
            \.$playlist
        }
    }

    func perform() async throws -> some IntentResult {
        guard let server = await MainActor.run(body: { ServerStore.shared.activeServer }) else {
            throw ShortcutPlaybackError.noActiveServer
        }
        let reference = ShortcutPlayableReference(
            serverConfigID: server.id.uuidString,
            kind: .playlist,
            contentID: playlist.id
        )
        try await playback.execute(.playable(reference, order: .inOrder))
        return .result()
    }
}

struct ShelvShufflePlaylistIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_shuffle_playlist_title"
    static let description = IntentDescription("shortcut_shuffle_playlist_description")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .background

    @Parameter(title: "shortcut_playlist_parameter")
    var playlist: ShelvPlaylistEntity

    @Dependency private var playback: ShortcutPlaybackCoordinator

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_shuffle_playlist_summary") {
            \.$playlist
        }
    }

    func perform() async throws -> some IntentResult {
        guard let server = await MainActor.run(body: { ServerStore.shared.activeServer }) else {
            throw ShortcutPlaybackError.noActiveServer
        }
        let reference = ShortcutPlayableReference(
            serverConfigID: server.id.uuidString,
            kind: .playlist,
            contentID: playlist.id
        )
        try await playback.execute(.playable(reference, order: .shuffled))
        return .result()
    }
}

@MainActor
private func requestShortcutDestination(_ destination: ShelvShortcutDestination) {
    print("[Shortcuts] Request → \(destination.rawValue)")
    ShelvShortcutHandoff.request(destination)
}

struct ShelvOpenPlayerIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut_open_player_title"
    static let description = IntentDescription("shortcut_open_player_description")
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        await requestShortcutDestination(.nowPlaying)
        return .result()
    }
}

struct ShelvOpenSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut_open_search_title"
    static let description = IntentDescription("shortcut_open_search_description")
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        await requestShortcutDestination(.search)
        return .result()
    }
}

struct ShelvOpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut_open_library_title"
    static let description = IntentDescription("shortcut_open_library_description")
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        await requestShortcutDestination(.library)
        return .result()
    }
}

struct ShelvOpenRecapIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut_open_recap_title"
    static let description = IntentDescription("shortcut_open_recap_description")
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        await requestShortcutDestination(.recap)
        return .result()
    }
}

struct ShelvAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .purple }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShelvShuffleAllIntent(),
            phrases: [
                "Shuffle all in \(.applicationName)",
                "Shuffle all tracks in \(.applicationName)",
                "Shuffle all songs in \(.applicationName)",
                "Shuffle my library in \(.applicationName)",
                "Ask \(.applicationName) to shuffle music",
                "Shuffle music with \(.applicationName)",
            ],
            shortTitle: "shortcut_shuffle_all_short",
            systemImageName: "shuffle"
        )

        AppShortcut(
            intent: ShelvPlayPlayableIntent(),
            phrases: [
                "Play something in \(.applicationName)",
                "Play \(\.$playable) in \(.applicationName)",
                "Ask \(.applicationName) to play \(\.$playable)",
                "Play \(\.$playable) with \(.applicationName)",
            ],
            shortTitle: "shortcut_play_short",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: ShelvPlayMixIntent(),
            phrases: [
                "Play a mix in \(.applicationName)",
                "Play \(\.$mix) in \(.applicationName)",
                "Play \(\.$mix) tracks in \(.applicationName)",
                "Start \(\.$mix) in \(.applicationName)",
            ],
            shortTitle: "shortcut_play_mix_short",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: ShelvInstantMixIntent(),
            phrases: [
                "Ask \(.applicationName) to play an instant mix",
                "Play an instant mix in \(.applicationName)",
                "Play instant mix for \(\.$playable) in \(.applicationName)",
                "Play an instant mix for \(\.$playable) in \(.applicationName)",
                "Create an instant mix from \(\.$playable) in \(.applicationName)",
                "Ask \(.applicationName) to play an instant mix for \(\.$playable)",
                "Start an instant mix for \(\.$playable) in \(.applicationName)",
                "Create an instant mix based on \(\.$playable) in \(.applicationName)",
                "Play music like \(\.$playable) in \(.applicationName)",
                "Create a station from \(\.$playable) in \(.applicationName)",
            ],
            shortTitle: "shortcut_instant_mix_short",
            systemImageName: "wand.and.stars"
        )

        AppShortcut(
            intent: ShelvPlayDownloadsIntent(),
            phrases: [
                "Play downloads in \(.applicationName)",
                "Play \(\.$mode) downloads in \(.applicationName)",
                "Play downloaded music in \(.applicationName)",
                "Shuffle downloads in \(.applicationName)",
            ],
            shortTitle: "shortcut_play_downloads_short",
            systemImageName: "arrow.down.circle.fill"
        )

        AppShortcut(
            intent: ShelvPlayPauseIntent(),
            phrases: [
                "Play or pause \(.applicationName)",
                "Toggle playback in \(.applicationName)",
                "Toggle \(.applicationName) playback",
                "Play or pause music in \(.applicationName)",
            ],
            shortTitle: "shortcut_play_pause_short",
            systemImageName: "playpause.fill"
        )

        AppShortcut(
            intent: ShelvOpenPlayerIntent(),
            phrases: [
                "Open player in \(.applicationName)",
                "Open \(.applicationName) player",
                "Show player in \(.applicationName)",
                "Open Now Playing in \(.applicationName)",
                "Show Now Playing in \(.applicationName)",
            ],
            shortTitle: "shortcut_now_playing_short",
            systemImageName: "music.note"
        )

        AppShortcut(
            intent: ShelvOpenSearchIntent(),
            phrases: [
                "Open search in \(.applicationName)",
                "Search in \(.applicationName)",
                "Show search in \(.applicationName)",
            ],
            shortTitle: "shortcut_search_short",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: ShelvOpenLibraryIntent(),
            phrases: [
                "Open library in \(.applicationName)",
                "Show library in \(.applicationName)",
                "Open my library in \(.applicationName)",
                "Show my library in \(.applicationName)",
            ],
            shortTitle: "shortcut_library_short",
            systemImageName: "books.vertical.fill"
        )

        AppShortcut(
            intent: ShelvOpenRecapIntent(),
            phrases: [
                "Open Recap in \(.applicationName)",
                "Show Recap in \(.applicationName)",
                "Open my Recap in \(.applicationName)",
                "Show my Recap in \(.applicationName)",
            ],
            shortTitle: "shortcut_recap_short",
            systemImageName: "calendar.badge.clock"
        )
    }
}
