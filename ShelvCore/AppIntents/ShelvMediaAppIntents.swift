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
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(String(format: String(localized: "shortcut_track_count_format"), trackCount))",
            image: .init(systemName: "music.note.list"),
            synonyms: ["\(title) playlist", "playlist \(title)"]
        )
    }

    var reference: ShortcutPlayableReference? {
        ShortcutPlayableReference(identifier: id)
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
}

@available(iOS 27.0, macOS 27.0, *)
struct ShelvAudioPlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvAudioPlaylistEntity.ID]) async throws -> [ShelvAudioPlaylistEntity] {
        try await ShelvIntentCatalog.shared.items(for: identifiers)
            .filter { $0.reference.kind == .playlist }
            .map(ShelvAudioPlaylistEntity.init)
    }

    func suggestedEntities() async throws -> [ShelvAudioPlaylistEntity] {
        try await ShelvIntentCatalog.shared.suggestedItems(allowedKinds: [.playlist])
            .map(ShelvAudioPlaylistEntity.init)
    }

    func entities(matching string: String) async throws -> [ShelvAudioPlaylistEntity] {
        try await ShelvIntentCatalog.shared.items(matching: string, allowedKinds: [.playlist])
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

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum ShelvAudioEntity {
    case song(ShelvAudioSongEntity)
    case album(ShelvAudioAlbumEntity)
    case artist(ShelvAudioArtistEntity)
    case playlist(ShelvAudioPlaylistEntity)
    case radio(ShelvAudioRadioEntity)

    var reference: ShortcutPlayableReference? {
        switch self {
        case .song(let entity): entity.reference
        case .album(let entity): entity.reference
        case .artist(let entity): entity.reference
        case .playlist(let entity): entity.reference
        case .radio(let entity): entity.reference
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension ShelvAudioEntity {
    struct AudioIntentValueQuery: IntentValueQuery {
        func values(for input: AudioSearch) async throws -> [ShelvAudioEntity] {
            let items: [ShelvIntentCatalogItem]
            switch input.criteria {
            case .searchQuery(let query):
                items = try await ShelvIntentCatalog.shared.items(
                    matching: query,
                    requiresExplicitRadio: true
                )
            case .unspecified:
                items = try await ShelvIntentCatalog.shared.suggestedItems()
            case .url:
                items = []
            default:
                items = []
            }
            return items.compactMap(Self.entity)
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

    @MainActor
    func perform() async throws -> some IntentResult {
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
        return .result()
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
        return .result()
    }
}
#endif
