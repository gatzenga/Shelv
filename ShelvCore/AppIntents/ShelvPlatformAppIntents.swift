#if os(macOS) || os(tvOS)
import AppIntents
import Foundation

struct ShelvPlatformPlayableEntity: AppEntity, Identifiable, Hashable, Sendable {
    let reference: ShortcutPlayableReference
    let title: String
    let subtitle: String?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_playable_type"
    static let defaultQuery = ShelvPlatformPlayableQuery()

    var id: String { reference.identifier }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" },
            image: .init(systemName: reference.kind.systemImageName),
            synonyms: spokenSynonyms
        )
    }

    init(item: ShelvIntentCatalogItem) {
        reference = item.reference
        title = item.title
        subtitle = item.subtitle
    }

    private var spokenSynonyms: [LocalizedStringResource] {
        switch reference.kind {
        case .song:
            return ["song \(title)", "track \(title)"]
        case .album:
            return ["album \(title)"]
        case .artist:
            return [
                "artist \(title)", "the artist \(title)",
                "music by \(title)", "songs by \(title)",
            ]
        case .playlist:
            return ["\(title) playlist", "playlist \(title)"]
        case .radio:
            return ["\(title) radio", "\(title) station"]
        }
    }
}

private extension ShortcutPlayableKind {
    var systemImageName: String {
        switch self {
        case .song: "music.note"
        case .album: "square.stack.fill"
        case .artist: "music.microphone"
        case .playlist: "music.note.list"
        case .radio: "dot.radiowaves.left.and.right"
        }
    }
}

struct ShelvPlatformPlayableQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvPlatformPlayableEntity.ID]) async throws -> [ShelvPlatformPlayableEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .map(ShelvPlatformPlayableEntity.init)
    }

    func suggestedEntities() async throws -> [ShelvPlatformPlayableEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems()
            .map(ShelvPlatformPlayableEntity.init)
    }

    func entities(matching string: String) async throws -> [ShelvPlatformPlayableEntity] {
        try await ShelvIntentCatalog.shared.items(matching: string)
            .map(ShelvPlatformPlayableEntity.init)
    }
}

struct ShelvPlatformShuffleSourceEntity: AppEntity, Identifiable, Hashable, Sendable {
    let playable: ShelvPlatformPlayableEntity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_shuffle_source_type"
    static let defaultQuery = ShelvPlatformShuffleSourceQuery()

    var id: String { playable.id }
    var displayRepresentation: DisplayRepresentation { playable.displayRepresentation }
    var reference: ShortcutPlayableReference { playable.reference }
}

struct ShelvPlatformShuffleSourceQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvPlatformShuffleSourceEntity.ID]) async throws -> [ShelvPlatformShuffleSourceEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .compactMap(Self.entity)
    }

    func suggestedEntities() async throws -> [ShelvPlatformShuffleSourceEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(
            allowedKinds: [.song, .album, .artist, .playlist]
        )
            .compactMap(Self.entity)
    }

    func entities(matching string: String) async throws -> [ShelvPlatformShuffleSourceEntity] {
        try await ShelvIntentCatalog.shared.items(
            matching: string,
            allowedKinds: [.song, .album, .artist, .playlist]
        )
            .compactMap(Self.entity)
    }

    private static func entity(_ item: ShelvIntentCatalogItem) -> ShelvPlatformShuffleSourceEntity? {
        guard item.reference.kind != .radio else { return nil }
        return ShelvPlatformShuffleSourceEntity(playable: .init(item: item))
    }
}

struct ShelvPlatformPlaylistEntity: AppEntity, Identifiable, Hashable, Sendable {
    let reference: ShortcutPlayableReference
    let title: String
    let trackCount: Int?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_playlist_type"
    static let defaultQuery = ShelvPlatformPlaylistQuery()

    var id: String { reference.identifier }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: trackCount.map {
                "\(String(format: String(localized: "shortcut_track_count_format"), $0))"
            },
            image: .init(systemName: "music.note.list"),
            synonyms: ["\(title) playlist", "playlist \(title)"]
        )
    }

    init(item: ShelvIntentCatalogItem) {
        reference = item.reference
        title = item.title
        trackCount = item.itemCount
    }
}

struct ShelvPlatformPlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvPlatformPlaylistEntity.ID]) async throws -> [ShelvPlatformPlaylistEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .filter { $0.reference.kind == .playlist }
            .map(ShelvPlatformPlaylistEntity.init)
    }

    func suggestedEntities() async throws -> [ShelvPlatformPlaylistEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(allowedKinds: [.playlist])
            .map(ShelvPlatformPlaylistEntity.init)
    }

    func entities(matching string: String) async throws -> [ShelvPlatformPlaylistEntity] {
        try await ShelvIntentCatalog.shared.items(
            matching: string,
            allowedKinds: [.playlist]
        )
            .map(ShelvPlatformPlaylistEntity.init)
    }
}

struct ShelvPlatformInstantMixEntity: AppEntity, Identifiable, Hashable, Sendable {
    let playable: ShelvPlatformPlayableEntity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_instant_mix_type"
    static let defaultQuery = ShelvPlatformInstantMixQuery()

    var id: String { playable.id }
    var displayRepresentation: DisplayRepresentation { playable.displayRepresentation }
}

struct ShelvPlatformInstantMixQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvPlatformInstantMixEntity.ID]) async throws -> [ShelvPlatformInstantMixEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .compactMap(Self.entity)
    }

    func suggestedEntities() async throws -> [ShelvPlatformInstantMixEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(
            allowedKinds: [.song, .album, .artist]
        )
            .compactMap(Self.entity)
    }

    func entities(matching string: String) async throws -> [ShelvPlatformInstantMixEntity] {
        try await ShelvIntentCatalog.shared.items(
            matching: string,
            allowedKinds: [.song, .album, .artist]
        )
            .compactMap(Self.entity)
    }

    private static func entity(_ item: ShelvIntentCatalogItem) -> ShelvPlatformInstantMixEntity? {
        guard [.song, .album, .artist].contains(item.reference.kind) else { return nil }
        return ShelvPlatformInstantMixEntity(playable: .init(item: item))
    }
}

private protocol ShelvPlatformPlaybackIntent: AppIntent, AudioPlaybackIntent {}

extension ShelvPlatformPlaybackIntent {
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
}

// These actions remain available in the Shortcuts action catalog. Only tvOS
// publishes natural-language playback phrases below because it has no native
// Media Intents route. On macOS 27, the audio schema is the single Siri route.
struct ShelvPlatformShuffleAllIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_shuffle_all_title"
    static let description = IntentDescription("shortcut_shuffle_all_description")

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.execute(.mix(.shuffleAll))
        return .result()
    }
}

struct ShelvPlatformPlayPlayableIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_title"
    static let description = IntentDescription("shortcut_play_description")

    @Parameter(title: "shortcut_playable_parameter")
    var playable: ShelvPlatformPlayableEntity

    @Parameter(title: "shortcut_order_parameter", default: .inOrder)
    var order: ShortcutPlaybackOrder

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_play_summary") {
            \.$playable
            \.$order
        }
    }

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.play(playable.reference, order: order)
        return .result()
    }
}

struct ShelvPlatformShufflePlayableIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_shuffle_playable_title"
    static let description = IntentDescription("shortcut_shuffle_playable_description")

    @Parameter(title: "shortcut_playable_parameter")
    var playable: ShelvPlatformShuffleSourceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_shuffle_playable_summary") { \.$playable }
    }

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.play(
            playable.reference,
            order: .shuffled
        )
        return .result()
    }
}

struct ShelvPlatformPlayMixIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_mix_title"
    static let description = IntentDescription("shortcut_play_mix_description")

    @Parameter(title: "shortcut_mix_parameter", default: .shuffleAll)
    var mix: ShortcutSmartMix

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_play_mix_summary") { \.$mix }
    }

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.execute(.mix(mix))
        return .result()
    }
}

struct ShelvPlatformPlayPlaylistIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_playlist_title"
    static let description = IntentDescription("shortcut_play_playlist_description")

    @Parameter(title: "shortcut_playlist_parameter")
    var playlist: ShelvPlatformPlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_play_playlist_summary") { \.$playlist }
    }

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.play(
            playlist.reference,
            order: .inOrder
        )
        return .result()
    }
}

struct ShelvPlatformShufflePlaylistIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_shuffle_playlist_title"
    static let description = IntentDescription("shortcut_shuffle_playlist_description")

    @Parameter(title: "shortcut_playlist_parameter")
    var playlist: ShelvPlatformPlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_shuffle_playlist_summary") { \.$playlist }
    }

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.play(
            playlist.reference,
            order: .shuffled
        )
        return .result()
    }
}

#if os(macOS)
struct ShelvPlatformPlayDownloadsIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_downloads_title"
    static let description = IntentDescription("shortcut_play_downloads_description")

    @Parameter(title: "shortcut_downloads_parameter", default: .shuffled)
    var mode: ShortcutDownloadsMode

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_play_downloads_summary") { \.$mode }
    }

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.execute(.downloads(mode))
        return .result()
    }
}
#endif

struct ShelvPlatformInstantMixIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_instant_mix_title"
    static let description = IntentDescription("shortcut_instant_mix_description")

    @Parameter(title: "shortcut_instant_mix_parameter")
    var playable: ShelvPlatformInstantMixEntity

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_instant_mix_summary") { \.$playable }
    }

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.execute(
            .instantMix(playable.playable.reference)
        )
        return .result()
    }
}

struct ShelvPlatformPlayPauseIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_play_pause_title"
    static let description = IntentDescription("shortcut_play_pause_description")

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.execute(.playPause)
        return .result()
    }
}

struct ShelvPlatformNextTrackIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_next_title"
    static let description = IntentDescription("shortcut_next_description")

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.execute(.next)
        return .result()
    }
}

struct ShelvPlatformPreviousTrackIntent: ShelvPlatformPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_previous_title"
    static let description = IntentDescription("shortcut_previous_description")

    func perform() async throws -> some IntentResult {
        try await ShelvSystemIntentPlaybackService.shared.execute(.previous)
        return .result()
    }
}

private protocol ShelvPlatformNavigationIntent: AppIntent {
    static var destination: ShelvShortcutDestination { get }
}

extension ShelvPlatformNavigationIntent {
    func perform() async throws -> some IntentResult {
        ShelvShortcutHandoff.request(Self.destination)
        return .result()
    }
}

struct ShelvPlatformOpenPlayerIntent: ShelvPlatformNavigationIntent {
    static let title: LocalizedStringResource = "shortcut_open_player_title"
    static let description = IntentDescription("shortcut_open_player_description")
    static let openAppWhenRun = true
    @available(macOS 26.0, tvOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let destination = ShelvShortcutDestination.nowPlaying
}

struct ShelvPlatformOpenSearchIntent: ShelvPlatformNavigationIntent {
    static let title: LocalizedStringResource = "shortcut_open_search_title"
    static let description = IntentDescription("shortcut_open_search_description")
    static let openAppWhenRun = true
    @available(macOS 26.0, tvOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let destination = ShelvShortcutDestination.search
}

struct ShelvPlatformOpenLibraryIntent: ShelvPlatformNavigationIntent {
    static let title: LocalizedStringResource = "shortcut_open_library_title"
    static let description = IntentDescription("shortcut_open_library_description")
    static let openAppWhenRun = true
    @available(macOS 26.0, tvOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let destination = ShelvShortcutDestination.library
}

struct ShelvPlatformOpenRecapIntent: ShelvPlatformNavigationIntent {
    static let title: LocalizedStringResource = "shortcut_open_recap_title"
    static let description = IntentDescription("shortcut_open_recap_description")
    static let openAppWhenRun = true
    @available(macOS 26.0, tvOS 26.0, *)
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let destination = ShelvShortcutDestination.recap
}

struct ShelvPlatformAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .purple }

    static var appShortcuts: [AppShortcut] {
        #if os(tvOS)
        AppShortcut(
            intent: ShelvPlatformShuffleAllIntent(),
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
            intent: ShelvPlatformPlayPlayableIntent(),
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
            intent: ShelvPlatformShufflePlayableIntent(),
            phrases: [
                "Ask \(.applicationName) to shuffle \(\.$playable)",
                "Play \(\.$playable) shuffled with \(.applicationName)",
                "Choose music to shuffle in \(.applicationName)",
            ],
            shortTitle: "shortcut_shuffle_playable_short",
            systemImageName: "shuffle"
        )

        AppShortcut(
            intent: ShelvPlatformPlayMixIntent(),
            phrases: [
                "Play a mix in \(.applicationName)",
                "Play \(\.$mix) in \(.applicationName)",
                "Play \(\.$mix) tracks in \(.applicationName)",
                "Start \(\.$mix) in \(.applicationName)",
                "Ask \(.applicationName) to play the \(\.$mix) mix",
                "Play the \(\.$mix) mix in \(.applicationName)",
            ],
            shortTitle: "shortcut_play_mix_short",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: ShelvPlatformPlayPlaylistIntent(),
            phrases: [
                "Play a playlist in \(.applicationName)",
                "Play playlist \(\.$playlist) in \(.applicationName)",
                "Ask \(.applicationName) to play playlist \(\.$playlist)",
            ],
            shortTitle: "shortcut_play_playlist_short",
            systemImageName: "music.note.list"
        )

        AppShortcut(
            intent: ShelvPlatformInstantMixIntent(),
            phrases: [
                "Ask \(.applicationName) to play an instant mix",
                "Play an instant mix in \(.applicationName)",
                "Play instant mix for \(\.$playable) in \(.applicationName)",
                "Play an instant mix for \(\.$playable) in \(.applicationName)",
                "Create an instant mix from \(\.$playable) in \(.applicationName)",
                "Ask \(.applicationName) to play an instant mix for \(\.$playable)",
            ],
            shortTitle: "shortcut_instant_mix_short",
            systemImageName: "wand.and.stars"
        )

        AppShortcut(
            intent: ShelvPlatformPlayPauseIntent(),
            phrases: [
                "Play or pause \(.applicationName)",
                "Toggle playback in \(.applicationName)",
                "Toggle \(.applicationName) playback",
                "Play or pause music in \(.applicationName)",
            ],
            shortTitle: "shortcut_play_pause_short",
            systemImageName: "playpause.fill"
        )
        #endif

        AppShortcut(
            intent: ShelvPlatformOpenPlayerIntent(),
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

        #if os(macOS)
        AppShortcut(
            intent: ShelvPlatformOpenSearchIntent(),
            phrases: [
                "Open search in \(.applicationName)",
                "Search in \(.applicationName)",
                "Show search in \(.applicationName)",
            ],
            shortTitle: "shortcut_search_short",
            systemImageName: "magnifyingglass"
        )
        #endif

        AppShortcut(
            intent: ShelvPlatformOpenLibraryIntent(),
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
            intent: ShelvPlatformOpenRecapIntent(),
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
#endif
