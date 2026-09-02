import AppIntents
import Foundation

/// Playlist picker for the dedicated "Play Playlist" action. Its identifiers
/// stay bare Navidrome playlist IDs so shortcuts people already configured keep
/// working, while lookup and search go through ``ShelvIntentCatalog`` like every
/// other Siri and Shortcuts route. That shared boundary is what makes offline
/// fallbacks, server scoping and match ranking behave identically everywhere.
struct ShelvPlaylistEntity: AppEntity, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let songCount: Int?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_playlist_type"
    static let defaultQuery = ShelvPlaylistQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: songCount.map {
                "\(String(format: String(localized: "shortcut_track_count_format"), $0))"
            },
            image: .init(systemName: "music.note.list"),
            synonyms: ["\(name) playlist", "playlist \(name)"]
        )
    }

    init(item: ShelvIntentCatalogItem) {
        id = item.reference.contentID
        name = item.title
        songCount = item.itemCount
    }
}

struct ShelvPlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvPlaylistEntity.ID]) async throws -> [ShelvPlaylistEntity] {
        try await ShelvIntentCatalog.shared
            .items(for: identifiers, kind: .playlist)
            .map(ShelvPlaylistEntity.init)
    }

    func suggestedEntities() async throws -> [ShelvPlaylistEntity] {
        try await ShelvIntentCatalog.shared
            .suggestedItems(limit: 25, allowedKinds: [.playlist])
            .map(ShelvPlaylistEntity.init)
    }

    func entities(matching string: String) async throws -> [ShelvPlaylistEntity] {
        try await ShelvIntentCatalog.shared
            .items(matching: string, kind: .playlist, limit: 25)
            .map(ShelvPlaylistEntity.init)
    }
}

struct ShelvPlayPauseIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_pause_title"
    static let description = IntentDescription("shortcut_play_pause_description")

    @Dependency private var playback: ShortcutPlaybackCoordinator

    func perform() async throws -> some IntentResult {
        try await playback.execute(.playPause)
        return .result()
    }
}

// Siri routes spoken "next"/"previous" through MPRemoteCommandCenter, which
// Shelv already answers. These stay as Shortcuts actions for automations.
struct ShelvNextTrackIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_next_title"
    static let description = IntentDescription("shortcut_next_description")

    @Dependency private var playback: ShortcutPlaybackCoordinator

    func perform() async throws -> some IntentResult {
        try await playback.execute(.next)
        return .result()
    }
}

struct ShelvPreviousTrackIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_previous_title"
    static let description = IntentDescription("shortcut_previous_description")

    @Dependency private var playback: ShortcutPlaybackCoordinator

    func perform() async throws -> some IntentResult {
        try await playback.execute(.previous)
        return .result()
    }
}

struct ShelvPlayPlaylistIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_playlist_title"
    static let description = IntentDescription("shortcut_play_playlist_description")

    @Parameter(title: "shortcut_playlist_parameter")
    var playlist: ShelvPlaylistEntity

    @Parameter(title: "shortcut_order_parameter", default: .inOrder)
    var order: ShortcutPlaybackOrder

    @Dependency private var playback: ShortcutPlaybackCoordinator

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_play_playlist_summary") {
            \.$playlist
            \.$order
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Running from Siri or an automation launches Shelv in the background,
        // where the server store is still loading. Reading it straight away
        // would report "no server" for a configured app.
        await ServerStore.shared.waitUntilReady()
        guard let server = ServerStore.shared.activeServer else {
            throw ShortcutPlaybackError.noActiveServer
        }
        // The entity carries a bare playlist ID, so it is scoped to whichever
        // server is active now. A playlist from a different server simply is
        // not found, which the playback service reports accurately.
        let reference = ShortcutPlayableReference(
            serverConfigID: server.id.uuidString,
            kind: .playlist,
            contentID: playlist.id
        )
        try await playback.execute(.playable(reference, order: order))
        return .result()
    }
}

@MainActor
private func requestShortcutDestination(_ destination: ShelvShortcutDestination) {
    ShelvIntentDiagnostics.received(route: "appShortcut.open.\(destination.rawValue)")
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

struct ShelvAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .purple }

    /// A provider may publish at most ten App Shortcuts, and this list is
    /// already at that ceiling — adding an eleventh fails the build. Spoken
    /// transport commands ("next", "pause") and spoken shuffle requests do not
    /// need a slot: the first arrive through MPRemoteCommandCenter, the second
    /// through the media routes (the iOS 27 audio schema and SiriKit below).
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

    }
}
