import AppIntents
import Foundation

struct ShelvPlayableEntity: AppEntity, Identifiable, Hashable, Sendable {
    let serverConfigID: String
    let kind: ShortcutPlayableKind
    let contentID: String
    let name: String
    let detail: String?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_playable_type"
    static let defaultQuery = ShelvPlayableQuery()

    var id: String { reference.identifier }

    var displayRepresentation: DisplayRepresentation {
        let kindName = String(localized: kind.localizedName)
        let subtitle = [detail, kindName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            synonyms: spokenSynonyms
        )
    }

    private var spokenSynonyms: [LocalizedStringResource] {
        switch kind {
        case .song:
            return ["song \(name)", "track \(name)"]
        case .album:
            return ["album \(name)"]
        case .artist:
            return [
                "artist \(name)", "the artist \(name)",
                "music by \(name)", "songs by \(name)",
            ]
        case .playlist:
            return ["\(name) playlist", "playlist \(name)"]
        case .radio:
            return ["\(name) radio", "\(name) station"]
        }
    }

    var reference: ShortcutPlayableReference {
        ShortcutPlayableReference(
            serverConfigID: serverConfigID,
            kind: kind,
            contentID: contentID
        )
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

/// A shuffle source can be any catalog item except a live radio station.
/// Keeping radio out of the entity query prevents Siri from offering a
/// semantically impossible "shuffle this station" action.
struct ShelvShuffleSourceEntity: AppEntity, Identifiable, Hashable, Sendable {
    let playable: ShelvPlayableEntity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "shortcut_shuffle_source_type"
    static let defaultQuery = ShelvShuffleSourceQuery()

    var id: String { playable.id }
    var displayRepresentation: DisplayRepresentation { playable.displayRepresentation }
    var reference: ShortcutPlayableReference { playable.reference }
}

struct ShelvShuffleSourceQuery: EntityStringQuery {
    private let playableQuery = ShelvPlayableQuery(
        allowedKinds: [.song, .album, .artist, .playlist]
    )

    func entities(for identifiers: [ShelvShuffleSourceEntity.ID]) async throws -> [ShelvShuffleSourceEntity] {
        try await playableQuery.entities(for: identifiers).compactMap(Self.wrap)
    }

    func suggestedEntities() async throws -> [ShelvShuffleSourceEntity] {
        try await playableQuery.suggestedEntities().compactMap(Self.wrap)
    }

    func entities(matching string: String) async throws -> [ShelvShuffleSourceEntity] {
        try await playableQuery.entities(matching: string).compactMap(Self.wrap)
    }

    private static func wrap(_ playable: ShelvPlayableEntity) -> ShelvShuffleSourceEntity? {
        guard playable.kind != .radio else { return nil }
        return ShelvShuffleSourceEntity(playable: playable)
    }
}

struct ShelvPlayableQuery: EntityStringQuery {
    private let allowedKinds: Set<ShortcutPlayableKind>

    init() {
        allowedKinds = Set(ShortcutPlayableKind.allCases)
    }

    init(allowedKinds: Set<ShortcutPlayableKind>) {
        self.allowedKinds = allowedKinds
    }

    func entities(for identifiers: [ShelvPlayableEntity.ID]) async throws -> [ShelvPlayableEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .filter { allowedKinds.contains($0.reference.kind) }
            .map(Self.entity)
    }

    func suggestedEntities() async throws -> [ShelvPlayableEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(
            limit: 40,
            allowedKinds: allowedKinds
        ).map(Self.entity)
    }

    func entities(matching string: String) async throws -> [ShelvPlayableEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        let matches = try await ShelvIntentCatalog.shared.items(
            matching: query,
            limit: 20,
            allowedKinds: allowedKinds
        )
        return ShelvIntentCatalog.deterministicPlaybackMatches(
            matches,
            query: query,
            ambiguityLimit: 10
        ).map(Self.entity)
    }

    private static func entity(_ item: ShelvIntentCatalogItem) -> ShelvPlayableEntity {
        let detail: String? = switch item.reference.kind {
        case .song, .album:
            item.artistName
        case .playlist:
            item.itemCount.map {
                String(format: String(localized: "shortcut_track_count_format"), $0)
            }
        case .artist, .radio:
            nil
        }
        return ShelvPlayableEntity(
            serverConfigID: item.reference.serverConfigID,
            kind: item.reference.kind,
            contentID: item.reference.contentID,
            name: item.title,
            detail: detail
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
        let seed = ShelvInstantMixIntentVocabulary.seedQuery(from: string)
            ?? string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return [] }
        return try await playableQuery.entities(matching: seed).compactMap(Self.wrap)
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

// Keep these App Shortcut actions available on iOS 27 and later. The native
// audio schema powers Siri's catalog search; it does not replace the explicit
// actions people select in the Shortcuts app.
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

struct ShelvShufflePlayableIntent: ShelvBackgroundPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_shuffle_playable_title"
    static let description = IntentDescription("shortcut_shuffle_playable_description")

    @Parameter(title: "shortcut_playable_parameter")
    var playable: ShelvShuffleSourceEntity

    @Dependency private var playback: ShortcutPlaybackCoordinator

    static var parameterSummary: some ParameterSummary {
        Summary("shortcut_shuffle_playable_summary") {
            \.$playable
        }
    }

    func perform() async throws -> some IntentResult {
        try await playback.execute(.playable(playable.reference, order: .shuffled))
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
