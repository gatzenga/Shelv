#if compiler(>=6.4) && canImport(MediaIntents) && !os(tvOS) && !os(watchOS)
import AppIntents
import Foundation
import MediaIntents

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.song)
struct ShelvAudioSongEntity {
    static let defaultQuery = ShelvAudioSongQuery()

    var title: String
    var artistName: String
    var albumTitle: String?
    var composerName: String?
    var internationalStandardRecordingCode: String?
    var album: ShelvAudioAlbumEntity?
    var artists: [ShelvAudioArtistEntity]
    var composers: [ShelvAudioArtistEntity]
    var duration: TimeInterval

    let id: String

    var displayRepresentation: DisplayRepresentation {
        let synonyms: [LocalizedStringResource] = artistName.isEmpty
            ? ["song \(title)", "track \(title)"]
            : ["\(title) by \(artistName)", "song \(title)", "track \(title)"]
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: artistName.isEmpty ? nil : "\(artistName)",
            image: .init(systemName: "music.note"),
            synonyms: synonyms
        )
    }

    var reference: ShortcutPlayableReference? {
        ShortcutPlayableReference(identifier: id)
    }

    init(item: ShelvIntentCatalogItem) {
        id = item.reference.identifier
        duration = item.duration ?? 0
        title = item.title
        artistName = item.artistName ?? ""
        albumTitle = item.albumTitle
        composerName = nil
        internationalStandardRecordingCode = item.internationalStandardRecordingCode
        if let artistID = item.artistID, let artistName = item.artistName {
            artists = [ShelvAudioArtistEntity(
                reference: .init(
                    serverConfigID: item.reference.serverConfigID,
                    kind: .artist,
                    contentID: artistID
                ),
                name: artistName
            )]
        } else {
            artists = []
        }
        if let albumID = item.albumID, let albumTitle = item.albumTitle {
            album = ShelvAudioAlbumEntity(
                reference: .init(
                    serverConfigID: item.reference.serverConfigID,
                    kind: .album,
                    contentID: albumID
                ),
                title: albumTitle,
                artistID: item.artistID,
                artistName: item.artistName
            )
        } else {
            album = nil
        }
        composers = []
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ShelvAudioSongQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvAudioSongEntity.ID]) async throws -> [ShelvAudioSongEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .filter { $0.reference.kind == .song }
            .map(ShelvAudioSongEntity.init)
    }

    func suggestedEntities() async throws -> [ShelvAudioSongEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(allowedKinds: [.song])
            .map(ShelvAudioSongEntity.init)
    }

    func entities(matching string: String) async throws -> [ShelvAudioSongEntity] {
        try await ShelvIntentCatalog.shared.items(matching: string, allowedKinds: [.song])
            .map(ShelvAudioSongEntity.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.album)
struct ShelvAudioAlbumEntity {
    static let defaultQuery = ShelvAudioAlbumQuery()

    var title: String
    var artistName: String
    var artists: [ShelvAudioArtistEntity]
    var universalProductCode: String?

    let id: String

    var displayRepresentation: DisplayRepresentation {
        let synonyms: [LocalizedStringResource] = artistName.isEmpty
            ? ["album \(title)"]
            : ["album \(title)", "\(title) by \(artistName)"]
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: artistName.isEmpty ? nil : "\(artistName)",
            image: .init(systemName: "square.stack.fill"),
            synonyms: synonyms
        )
    }

    var reference: ShortcutPlayableReference? {
        ShortcutPlayableReference(identifier: id)
    }

    init(item: ShelvIntentCatalogItem) {
        self.init(
            reference: item.reference,
            title: item.title,
            artistID: item.artistID,
            artistName: item.artistName
        )
    }

    init(
        reference: ShortcutPlayableReference,
        title: String,
        artistID: String?,
        artistName: String?
    ) {
        id = reference.identifier
        self.title = title
        self.artistName = artistName ?? ""
        if let artistID, let artistName {
            artists = [ShelvAudioArtistEntity(
                reference: .init(
                    serverConfigID: reference.serverConfigID,
                    kind: .artist,
                    contentID: artistID
                ),
                name: artistName
            )]
        } else {
            artists = []
        }
        universalProductCode = nil
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ShelvAudioAlbumQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvAudioAlbumEntity.ID]) async throws -> [ShelvAudioAlbumEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .filter { $0.reference.kind == .album }
            .map(ShelvAudioAlbumEntity.init)
    }

    func suggestedEntities() async throws -> [ShelvAudioAlbumEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(allowedKinds: [.album])
            .map(ShelvAudioAlbumEntity.init)
    }

    func entities(matching string: String) async throws -> [ShelvAudioAlbumEntity] {
        try await ShelvIntentCatalog.shared.items(matching: string, allowedKinds: [.album])
            .map(ShelvAudioAlbumEntity.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct ShelvAudioArtistEntity {
    static let defaultQuery = ShelvAudioArtistQuery()

    var name: String
    var albums: [ShelvAudioAlbumEntity]
    var songs: [ShelvAudioSongEntity]

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            image: .init(systemName: "music.microphone"),
            synonyms: ["music by \(name)", "songs by \(name)"]
        )
    }

    var reference: ShortcutPlayableReference? {
        ShortcutPlayableReference(identifier: id)
    }

    init(item: ShelvIntentCatalogItem) {
        self.init(reference: item.reference, name: item.title)
    }

    init(reference: ShortcutPlayableReference, name: String) {
        id = reference.identifier
        albums = []
        songs = []
        self.name = name
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ShelvAudioArtistQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvAudioArtistEntity.ID]) async throws -> [ShelvAudioArtistEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .filter { $0.reference.kind == .artist }
            .map(ShelvAudioArtistEntity.init)
    }

    func suggestedEntities() async throws -> [ShelvAudioArtistEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(allowedKinds: [.artist])
            .map(ShelvAudioArtistEntity.init)
    }

    func entities(matching string: String) async throws -> [ShelvAudioArtistEntity] {
        try await ShelvIntentCatalog.shared.items(matching: string, allowedKinds: [.artist])
            .map(ShelvAudioArtistEntity.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum ShelvPlaylistOwner {
    case curator(String)
    case person(IntentPerson)
}

nonisolated private enum ShelvAudioSmartMixIdentifier {
    private static let prefix = "shelv-smart-mix:"

    static func identifier(for mix: ShortcutSmartMix) -> String {
        prefix + mix.rawValue
    }

    static func mix(from identifier: String) -> ShortcutSmartMix? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return ShortcutSmartMix(rawValue: String(identifier.dropFirst(prefix.count)))
    }
}

nonisolated private enum ShelvAudioDownloadsIdentifier {
    private static let prefix = "shelv-downloads:"

    static func identifier(for mode: ShortcutDownloadsMode) -> String {
        prefix + mode.rawValue
    }

    static func mode(from identifier: String) -> ShortcutDownloadsMode? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return ShortcutDownloadsMode(rawValue: String(identifier.dropFirst(prefix.count)))
    }
}

nonisolated private enum ShelvAudioInstantMixIdentifier {
    private static let prefix = "shelv-instant-mix:"

    static func identifier(for reference: ShortcutPlayableReference) -> String {
        prefix + reference.identifier
    }

    static func reference(from identifier: String) -> ShortcutPlayableReference? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return ShortcutPlayableReference(
            identifier: String(identifier.dropFirst(prefix.count))
        )
    }
}

nonisolated private extension ShortcutSmartMix {
    var audioEntityTitle: String {
        switch self {
        case .newest: String(localized: "shortcut_mix_newest")
        case .frequent: String(localized: "shortcut_mix_frequent")
        case .recent: String(localized: "shortcut_mix_recent")
        case .shuffleAll: String(localized: "shortcut_shuffle_all")
        }
    }

    var audioEntitySynonyms: [LocalizedStringResource] {
        switch self {
        case .newest: ["Newest Tracks", "Latest Tracks", "Latest Music", "New Music"]
        case .frequent: ["Frequently Played Tracks", "Most Played", "Top Tracks"]
        case .recent: ["Recently Played Tracks", "Recent Tracks", "Recent Music"]
        case .shuffleAll: ["Shuffle All Tracks", "Shuffle All Songs", "Shuffle My Library"]
        }
    }
}

nonisolated private extension ShortcutDownloadsMode {
    var audioEntityTitle: String {
        switch self {
        case .all: String(localized: "shortcut_downloads_all")
        case .shuffled: String(localized: "shortcut_downloads_shuffled")
        case .newest: String(localized: "shortcut_downloads_newest")
        }
    }

    var audioEntitySynonyms: [LocalizedStringResource] {
        switch self {
        case .all: ["All Downloads", "All Downloaded Music", "Downloaded Tracks"]
        case .shuffled: ["Downloads", "Shuffle Downloads", "Downloaded Music"]
        case .newest: ["Newest Downloads", "Latest Downloads", "Newly Downloaded"]
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct ShelvAudioPlaylistEntity {
    static let defaultQuery = ShelvAudioPlaylistQuery()

    var title: String
    var owner: ShelvPlaylistOwner?
    var trackCount: Int
    var totalDuration: TimeInterval
    var createdByMe: Bool?
    var curatedForMe: Bool?

    let id: String

    var displayRepresentation: DisplayRepresentation {
        if let smartMix {
            return DisplayRepresentation(
                title: "\(title)",
                subtitle: "\(String(localized: "shortcut_mix_type"))",
                image: .init(systemName: "sparkles"),
                synonyms: smartMix.audioEntitySynonyms
            )
        }
        if let downloadsMode {
            return DisplayRepresentation(
                title: "\(title)",
                subtitle: "\(String(localized: "shortcut_downloads_type"))",
                image: .init(systemName: "arrow.down.circle.fill"),
                synonyms: downloadsMode.audioEntitySynonyms
            )
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(String(format: String(localized: "shortcut_track_count_format"), trackCount))",
            image: .init(systemName: "music.note.list"),
            synonyms: ["\(title) playlist", "playlist \(title)"]
        )
    }

    var reference: ShortcutPlayableReference? {
        guard smartMix == nil, downloadsMode == nil else { return nil }
        return ShortcutPlayableReference(identifier: id)
    }

    var smartMix: ShortcutSmartMix? {
        ShelvAudioSmartMixIdentifier.mix(from: id)
    }

    var downloadsMode: ShortcutDownloadsMode? {
        ShelvAudioDownloadsIdentifier.mode(from: id)
    }

    init(item: ShelvIntentCatalogItem) {
        id = item.reference.identifier
        trackCount = item.itemCount ?? 0
        totalDuration = item.duration ?? 0
        title = item.title
        owner = .curator("Shelv")
        createdByMe = true
        curatedForMe = false
    }

    init(smartMix: ShortcutSmartMix) {
        id = ShelvAudioSmartMixIdentifier.identifier(for: smartMix)
        trackCount = 0
        totalDuration = 0
        title = smartMix.audioEntityTitle
        owner = .curator("Shelv")
        createdByMe = false
        curatedForMe = true
    }

    init(downloadsMode: ShortcutDownloadsMode) {
        id = ShelvAudioDownloadsIdentifier.identifier(for: downloadsMode)
        trackCount = 0
        totalDuration = 0
        title = downloadsMode.audioEntityTitle
        owner = .curator("Shelv")
        createdByMe = true
        curatedForMe = true
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ShelvAudioPlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvAudioPlaylistEntity.ID]) async throws -> [ShelvAudioPlaylistEntity] {
        let catalogIdentifiers = identifiers.filter {
            ShelvAudioSmartMixIdentifier.mix(from: $0) == nil
                && ShelvAudioDownloadsIdentifier.mode(from: $0) == nil
        }
        let catalogEntities = try await ShelvIntentCatalog.shared.items(for: catalogIdentifiers)
            .filter { $0.reference.kind == .playlist }
            .map(ShelvAudioPlaylistEntity.init)
        let catalogByID = Dictionary(uniqueKeysWithValues: catalogEntities.map { ($0.id, $0) })
        return identifiers.compactMap { identifier in
            if let mix = ShelvAudioSmartMixIdentifier.mix(from: identifier) {
                return ShelvAudioPlaylistEntity(smartMix: mix)
            }
            if let mode = ShelvAudioDownloadsIdentifier.mode(from: identifier) {
                return ShelvAudioPlaylistEntity(downloadsMode: mode)
            }
            return catalogByID[identifier]
        }
    }

    func suggestedEntities() async throws -> [ShelvAudioPlaylistEntity] {
        let smartMixes = ShortcutSmartMix.allCases.map(ShelvAudioPlaylistEntity.init(smartMix:))
        let downloads = ShortcutDownloadsMode.allCases.map(
            ShelvAudioPlaylistEntity.init(downloadsMode:)
        )
        let playlists = try await ShelvIntentCatalog.shared.suggestedItems(allowedKinds: [.playlist])
            .map(ShelvAudioPlaylistEntity.init)
        return smartMixes + downloads + playlists
    }

    func entities(matching string: String) async throws -> [ShelvAudioPlaylistEntity] {
        if let mode = ShelvDownloadsIntentVocabulary.mode(for: string) {
            return [ShelvAudioPlaylistEntity(downloadsMode: mode)]
        }
        if let mix = ShelvSmartMixIntentVocabulary.smartMix(for: string) {
            return [ShelvAudioPlaylistEntity(smartMix: mix)]
        }
        return try await ShelvIntentCatalog.shared.items(matching: string, allowedKinds: [.playlist])
            .map(ShelvAudioPlaylistEntity.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.liveRadioStation)
struct ShelvAudioRadioEntity {
    static let defaultQuery = ShelvAudioRadioQuery()

    var title: String
    var providerName: String?

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "Shelv Radio",
            image: .init(systemName: "dot.radiowaves.left.and.right"),
            synonyms: ["\(title) radio", "\(title) station"]
        )
    }

    var reference: ShortcutPlayableReference? {
        ShortcutPlayableReference(identifier: id)
    }

    init(item: ShelvIntentCatalogItem) {
        id = item.reference.identifier
        title = item.title
        providerName = "Shelv"
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ShelvAudioRadioQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvAudioRadioEntity.ID]) async throws -> [ShelvAudioRadioEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .filter { $0.reference.kind == .radio }
            .map(ShelvAudioRadioEntity.init)
    }

    func suggestedEntities() async throws -> [ShelvAudioRadioEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(allowedKinds: [.radio])
            .map(ShelvAudioRadioEntity.init)
    }

    func entities(matching string: String) async throws -> [ShelvAudioRadioEntity] {
        try await ShelvIntentCatalog.shared.items(matching: string, allowedKinds: [.radio])
            .map(ShelvAudioRadioEntity.init)
    }
}

/// A seeded Shelv Instant Mix is algorithmic audio content, not a playlist.
/// Modeling it with Apple's matching schema keeps "instant mix for …" on the
/// native playAudio route instead of letting Siri search playlist names.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.algorithmicRadioStation)
struct ShelvAudioAlgorithmicStationEntity {
    static let defaultQuery = ShelvAudioAlgorithmicStationQuery()

    var title: String
    var curatedForMe: Bool?
    let id: String

    var displayRepresentation: DisplayRepresentation {
        let instantMixTitle = String(localized: "shortcut_instant_mix_title")
        return DisplayRepresentation(
            title: "\(instantMixTitle): \(title)",
            subtitle: "Shelv",
            image: .init(systemName: "wand.and.stars"),
            synonyms: [
                "Instant Mix for \(title)",
                "\(title) Instant Mix",
                "Music like \(title)",
            ]
        )
    }

    var seedReference: ShortcutPlayableReference? {
        ShelvAudioInstantMixIdentifier.reference(from: id)
    }

    init(item: ShelvIntentCatalogItem) {
        self.init(reference: item.reference, title: item.title)
    }

    init(reference: ShortcutPlayableReference, title: String) {
        id = ShelvAudioInstantMixIdentifier.identifier(for: reference)
        self.title = title
        curatedForMe = true
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ShelvAudioAlgorithmicStationQuery: EntityStringQuery {
    private static let allowedKinds: Set<ShortcutPlayableKind> = [.song, .album, .artist]

    func entities(
        for identifiers: [ShelvAudioAlgorithmicStationEntity.ID]
    ) async throws -> [ShelvAudioAlgorithmicStationEntity] {
        let references = identifiers.compactMap(ShelvAudioInstantMixIdentifier.reference(from:))
            .filter { Self.allowedKinds.contains($0.kind) }
        let items = try await ShelvIntentCatalog.shared.items(for: references)
        let itemsByReference = Dictionary(
            uniqueKeysWithValues: items.map { ($0.reference, $0) }
        )
        return identifiers.compactMap { identifier in
            guard let reference = ShelvAudioInstantMixIdentifier.reference(from: identifier),
                  let item = itemsByReference[reference]
            else { return nil }
            return ShelvAudioAlgorithmicStationEntity(item: item)
        }
    }

    func suggestedEntities() async throws -> [ShelvAudioAlgorithmicStationEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(
            limit: 12,
            allowedKinds: Self.allowedKinds
        ).map(ShelvAudioAlgorithmicStationEntity.init)
    }

    func entities(matching string: String) async throws -> [ShelvAudioAlgorithmicStationEntity] {
        let seed = ShelvInstantMixIntentVocabulary.seedQuery(from: string)
            ?? string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return [] }
        let matches = try await ShelvIntentCatalog.shared.items(
            matching: seed,
            limit: 10,
            requiresExplicitRadio: true,
            allowedKinds: Self.allowedKinds
        )
        return ShelvIntentCatalog.deterministicPlaybackMatches(matches, query: seed)
            .map(ShelvAudioAlgorithmicStationEntity.init)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum ShelvAudioEntity {
    case song(ShelvAudioSongEntity)
    case album(ShelvAudioAlbumEntity)
    case artist(ShelvAudioArtistEntity)
    case playlist(ShelvAudioPlaylistEntity)
    case radio(ShelvAudioRadioEntity)
    case algorithmicStation(ShelvAudioAlgorithmicStationEntity)

    var reference: ShortcutPlayableReference? {
        switch self {
        case .song(let entity): entity.reference
        case .album(let entity): entity.reference
        case .artist(let entity): entity.reference
        case .playlist(let entity): entity.reference
        case .radio(let entity): entity.reference
        case .algorithmicStation: nil
        }
    }

    var smartMix: ShortcutSmartMix? {
        guard case .playlist(let entity) = self else { return nil }
        return entity.smartMix
    }

    var downloadsMode: ShortcutDownloadsMode? {
        guard case .playlist(let entity) = self else { return nil }
        return entity.downloadsMode
    }

    var instantMixReference: ShortcutPlayableReference? {
        guard case .algorithmicStation(let entity) = self else { return nil }
        return entity.seedReference
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension ShelvAudioEntity {
    struct AudioIntentValueQuery: IntentValueQuery {
        func values(for input: AudioSearch) async throws -> [ShelvAudioEntity] {
            let criteria = Self.diagnosticCriteria(input.criteria)
            ShelvIntentDiagnostics.audioSearchBegan(criteria: criteria)

            do {
                let resolved: [ShelvAudioEntity]
                let route: String
                switch input.criteria {
                case .searchQuery(let query):
                    if let seed = ShelvInstantMixIntentVocabulary.seedQuery(from: query) {
                        let items = try await ShelvIntentCatalog.shared.items(
                            matching: seed,
                            limit: 10,
                            requiresExplicitRadio: true,
                            allowedKinds: [.song, .album, .artist]
                        )
                        resolved = ShelvIntentCatalog.deterministicPlaybackMatches(
                            items,
                            query: seed
                        ).map {
                            .algorithmicStation(ShelvAudioAlgorithmicStationEntity(item: $0))
                        }
                        route = "instantMix"
                    } else if let mode = ShelvDownloadsIntentVocabulary.mode(for: query) {
                        resolved = [.playlist(ShelvAudioPlaylistEntity(downloadsMode: mode))]
                        route = "downloads"
                    } else if let mix = ShelvSmartMixIntentVocabulary.smartMix(for: query) {
                        resolved = [.playlist(ShelvAudioPlaylistEntity(smartMix: mix))]
                        route = "smartMix"
                    } else {
                        let items = try await ShelvIntentCatalog.shared.items(
                            matching: query,
                            requiresExplicitRadio: true
                        )
                        resolved = ShelvIntentCatalog.deterministicPlaybackMatches(
                            items,
                            query: query
                        ).compactMap(Self.entity)
                        route = "catalog"
                    }
                case .unspecified:
                    let items = try await ShelvIntentCatalog.shared.suggestedItems()
                    resolved = items.compactMap(Self.entity)
                    route = "suggested"
                case .url:
                    resolved = []
                    route = "url"
                default:
                    resolved = []
                    route = "unsupported"
                }

                ShelvIntentDiagnostics.audioSearchCompleted(
                    criteria: criteria,
                    route: route,
                    resultCount: resolved.count
                )
                return resolved
            } catch {
                ShelvIntentDiagnostics.audioSearchFailed(criteria: criteria, error: error)
                throw error
            }
        }

        private static func diagnosticCriteria(_ criteria: AudioSearch.Criteria) -> String {
            switch criteria {
            case .searchQuery: "searchQuery"
            case .unspecified: "unspecified"
            case .url: "url"
            default: "unknown"
            }
        }

        private static func entity(_ item: ShelvIntentCatalogItem) -> ShelvAudioEntity? {
            switch item.reference.kind {
            case .song: .song(ShelvAudioSongEntity(item: item))
            case .album: .album(ShelvAudioAlbumEntity(item: item))
            case .artist: .artist(ShelvAudioArtistEntity(item: item))
            case .playlist: .playlist(ShelvAudioPlaylistEntity(item: item))
            case .radio: .radio(ShelvAudioRadioEntity(item: item))
            }
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum ShelvAudioPlaybackAttribute: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "shortcut_media_attribute_shuffle",
        .repeat: "shortcut_media_attribute_repeat"
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum ShelvAudioQueueLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "shortcut_media_queue_next",
        .tail: "shortcut_media_queue_last"
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct ShelvAudioWarmupResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        "shortcut_media_queue_ready"
    }

    init() {}
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct ShelvPlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_media_play_title"
    static let description = IntentDescription("shortcut_media_play_description")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    var audioEntity: ShelvAudioEntity

    @Parameter(default: [])
    var playbackAttributes: Set<ShelvAudioPlaybackAttribute>

    var warmupAudioQueueResult: ShelvAudioWarmupResult?
    var queueLocation: ShelvAudioQueueLocation?

    private var completionDialog: IntentDialog {
        IntentDialog(LocalizedStringResource("shortcut_media_playback_started"))
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let reference = audioEntity.instantMixReference {
            guard queueLocation == nil else {
                throw ShortcutPlaybackError.unsupportedQueueOperation
            }
            try await ShelvSystemIntentPlaybackService.shared.execute(.instantMix(reference))
            return .result(dialog: completionDialog)
        }
        if let mix = audioEntity.smartMix {
            guard queueLocation == nil else {
                throw ShortcutPlaybackError.unsupportedQueueOperation
            }
            try await ShelvSystemIntentPlaybackService.shared.execute(.mix(mix))
            return .result(dialog: completionDialog)
        }
        if let mode = audioEntity.downloadsMode {
            guard queueLocation == nil else {
                throw ShortcutPlaybackError.unsupportedQueueOperation
            }
            try await ShelvSystemIntentPlaybackService.shared.execute(.downloads(mode))
            return .result(dialog: completionDialog)
        }
        guard let reference = audioEntity.reference else {
            throw ShortcutPlaybackError.notFound
        }
        let placement: ShortcutQueuePlacement = switch queueLocation {
        case .next: .next
        case .tail: .tail
        case .none: .replace
        }
        try await ShelvSystemIntentPlaybackService.shared.play(
            reference,
            order: playbackAttributes.contains(.shuffle) ? .shuffled : .inOrder,
            placement: placement,
            repeats: playbackAttributes.contains(.repeat)
        )
        return .result(dialog: completionDialog)
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.createStation)
struct ShelvCreateStationIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "shortcut_media_create_station_title"
    static let description = IntentDescription("shortcut_media_create_station_description")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let reference = AudioPlayerService.shared.currentSongReferenceForSystemIntent() else {
            throw ShortcutPlaybackError.noPlayableContent
        }
        try await ShelvSystemIntentPlaybackService.shared.execute(.instantMix(reference))
        return .result(
            dialog: IntentDialog(LocalizedStringResource("shortcut_media_playback_started"))
        )
    }
}
#endif
