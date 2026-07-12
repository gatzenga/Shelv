#if os(iOS)
import Foundation
import Intents
import OSLog

/// Handles classic SiriKit media requests in the iOS app process. HomePod
/// forwards these requests to the user's primary iPhone, which lets this
/// handler reuse Shelv's authenticated catalog and normal playback pipeline.
@MainActor
final class ShelvSiriMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    static let shared = ShelvSiriMediaIntentHandler()

    private let logger = Logger(
        subsystem: "ch.vkugler.Shelv",
        category: "SiriMedia"
    )

    private override init() {
        super.init()
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        Task { @MainActor in
            do {
                let items = try await resolvedItems(for: intent)
                guard !items.isEmpty else {
                    completion([INPlayMediaMediaItemResolutionResult.unsupported()])
                    return
                }
                completion(INPlayMediaMediaItemResolutionResult.successes(with: items))
            } catch {
                logger.error(
                    "Siri media resolution failed error=\(String(describing: error), privacy: .private(mask: .hash))"
                )
                completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            }
        }
    }

    func confirm(
        intent: INPlayMediaIntent,
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        let code: INPlayMediaIntentResponseCode = ServerStore.shared.activeServer == nil
            ? .failureRequiringAppLaunch
            : .ready
        completion(INPlayMediaIntentResponse(code: code, userActivity: nil))
    }

    func handle(
        intent: INPlayMediaIntent,
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        Task { @MainActor in
            let code: INPlayMediaIntentResponseCode
            do {
                let payload: ShelvSiriMediaResolution
                if let identifier = intent.mediaItems?.first?.identifier,
                   let decoded = ShelvSiriMediaResolution(identifier: identifier) {
                    payload = decoded
                } else {
                    guard let item = try await resolvedItems(for: intent).first,
                          let identifier = item.identifier,
                          let decoded = ShelvSiriMediaResolution(identifier: identifier)
                    else {
                        throw ShortcutPlaybackError.notFound
                    }
                    payload = decoded
                }

                try await perform(payload)
                code = .success
                logger.notice("Siri media playback completed action=\(payload.action.rawValue, privacy: .public)")
            } catch let error as ShortcutPlaybackError {
                code = responseCode(for: error)
                logger.error("Siri media playback failed error=\(String(describing: error), privacy: .public)")
            } catch {
                code = .failure
                logger.error(
                    "Siri media playback failed error=\(String(describing: error), privacy: .private(mask: .hash))"
                )
            }
            completion(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
    }

    private func resolvedItems(for intent: INPlayMediaIntent) async throws -> [INMediaItem] {
        if let identifier = intent.mediaItems?.first?.identifier,
           ShelvSiriMediaResolution(identifier: identifier) != nil {
            return intent.mediaItems ?? []
        }

        let request = ShelvSiriMediaRequest(intent: intent)
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            guard let payload = payloadForQuerylessRequest(request) else { return [] }
            return [mediaItem(
                payload: payload,
                title: request.displayTitle,
                type: request.mediaType
            )]
        }

        if let mix = ShelvSmartMixIntentVocabulary.smartMix(for: query) {
            return [mediaItem(
                payload: .mix(mix),
                title: request.displayTitle,
                type: .music
            )]
        }

        let candidates = try await ShelvIntentCatalog.shared.items(
            matching: query,
            limit: 20,
            requiresExplicitRadio: false,
            allowedKinds: allowedKinds(for: request.mediaType)
        )
        let matches = ShelvIntentCatalog.deterministicPlaybackMatches(
            candidates,
            query: query
        )
        let placement = queuePlacement(for: request)
        let repeats = request.playbackRepeatModeRawValue != INPlaybackRepeatMode.none.rawValue
            && request.playbackRepeatModeRawValue != INPlaybackRepeatMode.unknown.rawValue

        return matches.prefix(5).map { match in
            let payload: ShelvSiriMediaResolution
            if isInstantMixType(request.mediaType) {
                payload = .instantMix(match.reference)
            } else {
                payload = .playable(
                    match.reference,
                    order: request.playShuffled ? .shuffled : .inOrder,
                    placement: placement,
                    repeats: repeats
                )
            }
            return mediaItem(
                payload: payload,
                title: match.title,
                type: mediaItemType(for: match.reference.kind)
            )
        }
    }

    private func payloadForQuerylessRequest(
        _ request: ShelvSiriMediaRequest
    ) -> ShelvSiriMediaResolution? {
        if request.mediaReferenceRawValue == INMediaReference.currentlyPlaying.rawValue {
            return .resume
        }
        switch INMediaSortOrder(rawValue: request.sortOrderRawValue) ?? .unknown {
        case .newest:
            return .mix(.newest)
        case .best, .popular, .trending, .recommended:
            return .mix(.frequent)
        default:
            guard request.sortOrderRawValue == INMediaSortOrder.unknown.rawValue else {
                return nil
            }
            return request.playShuffled || request.mediaType == .music
                ? .mix(.shuffleAll)
                : nil
        }
    }

    private func perform(_ payload: ShelvSiriMediaResolution) async throws {
        switch payload.action {
        case .playable:
            guard let reference = payload.reference,
                  let order = payload.order,
                  let placement = payload.placement
            else { throw ShortcutPlaybackError.notFound }
            try await ShelvSystemIntentPlaybackService.shared.play(
                reference,
                order: order,
                placement: placement,
                repeats: payload.repeats
            )
        case .instantMix:
            guard let reference = payload.reference else {
                throw ShortcutPlaybackError.notFound
            }
            try await ShelvSystemIntentPlaybackService.shared.execute(.instantMix(reference))
        case .mix:
            guard let mix = payload.mix else { throw ShortcutPlaybackError.notFound }
            try await ShelvSystemIntentPlaybackService.shared.execute(.mix(mix))
        case .resume:
            if !AudioPlayerService.shared.isPlaying {
                try await ShelvSystemIntentPlaybackService.shared.execute(.playPause)
            }
        }
    }

    private func responseCode(for error: ShortcutPlaybackError) -> INPlayMediaIntentResponseCode {
        switch error {
        case .notFound, .noPlayableContent, .instantMixUnavailable:
            .failureNoUnplayedContent
        case .noActiveServer:
            .failureRequiringAppLaunch
        default:
            .failure
        }
    }

    private func queuePlacement(
        for request: ShelvSiriMediaRequest
    ) -> ShortcutQueuePlacement {
        switch INPlaybackQueueLocation(rawValue: request.playbackQueueLocationRawValue) ?? .unknown {
        case .next: .next
        case .later: .tail
        default: .replace
        }
    }

    private func allowedKinds(for mediaType: INMediaItemType) -> Set<ShortcutPlayableKind> {
        switch mediaType {
        case .song: [.song]
        case .album: [.album]
        case .artist: [.artist]
        case .playlist, .podcastPlaylist: [.playlist]
        case .radioStation: [.radio]
        case .musicStation, .station, .algorithmicRadioStation: [.song, .album, .artist]
        default: [.song, .album, .artist, .playlist]
        }
    }

    private func isInstantMixType(_ mediaType: INMediaItemType) -> Bool {
        switch mediaType {
        case .musicStation, .station, .algorithmicRadioStation: true
        default: false
        }
    }

    private func mediaItem(
        payload: ShelvSiriMediaResolution,
        title: String,
        type: INMediaItemType
    ) -> INMediaItem {
        INMediaItem(
            identifier: payload.identifier,
            title: title,
            type: type,
            artwork: nil
        )
    }

    private func mediaItemType(for kind: ShortcutPlayableKind) -> INMediaItemType {
        switch kind {
        case .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        case .radio: .radioStation
        }
    }
}

nonisolated struct ShelvSiriMediaResolution: Codable, Hashable, Sendable {
    enum Action: String, Codable, Hashable, Sendable {
        case playable
        case instantMix
        case mix
        case resume
    }

    private static let identifierPrefix = "shelv-siri-resolution-v1:"

    let action: Action
    let referenceIdentifier: String?
    let orderRawValue: String?
    let placementRawValue: String?
    let repeats: Bool
    let mixRawValue: String?

    private init(
        action: Action,
        referenceIdentifier: String?,
        orderRawValue: String?,
        placementRawValue: String?,
        repeats: Bool,
        mixRawValue: String?
    ) {
        self.action = action
        self.referenceIdentifier = referenceIdentifier
        self.orderRawValue = orderRawValue
        self.placementRawValue = placementRawValue
        self.repeats = repeats
        self.mixRawValue = mixRawValue
    }

    static func playable(
        _ reference: ShortcutPlayableReference,
        order: ShortcutPlaybackOrder,
        placement: ShortcutQueuePlacement,
        repeats: Bool
    ) -> Self {
        Self(
            action: .playable,
            referenceIdentifier: reference.identifier,
            orderRawValue: order.rawValue,
            placementRawValue: placement.identifier,
            repeats: repeats,
            mixRawValue: nil
        )
    }

    static func instantMix(_ reference: ShortcutPlayableReference) -> Self {
        Self(
            action: .instantMix,
            referenceIdentifier: reference.identifier,
            orderRawValue: nil,
            placementRawValue: nil,
            repeats: false,
            mixRawValue: nil
        )
    }

    static func mix(_ mix: ShortcutSmartMix) -> Self {
        Self(
            action: .mix,
            referenceIdentifier: nil,
            orderRawValue: nil,
            placementRawValue: nil,
            repeats: false,
            mixRawValue: mix.rawValue
        )
    }

    static let resume = Self(
        action: .resume,
        referenceIdentifier: nil,
        orderRawValue: nil,
        placementRawValue: nil,
        repeats: false,
        mixRawValue: nil
    )

    init?(identifier: String) {
        guard identifier.hasPrefix(Self.identifierPrefix) else { return nil }
        var encoded = String(identifier.dropFirst(Self.identifierPrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = decoded
    }

    var identifier: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.identifierPrefix + encoded
    }

    var reference: ShortcutPlayableReference? {
        referenceIdentifier.flatMap(ShortcutPlayableReference.init(identifier:))
    }

    var order: ShortcutPlaybackOrder? {
        orderRawValue.flatMap(ShortcutPlaybackOrder.init(rawValue:))
    }

    var placement: ShortcutQueuePlacement? {
        placementRawValue.flatMap(ShortcutQueuePlacement.init(identifier:))
    }

    var mix: ShortcutSmartMix? {
        mixRawValue.flatMap(ShortcutSmartMix.init(rawValue:))
    }
}

private extension ShortcutQueuePlacement {
    nonisolated var identifier: String {
        switch self {
        case .replace: "replace"
        case .next: "next"
        case .tail: "tail"
        }
    }

    nonisolated init?(identifier: String) {
        switch identifier {
        case "replace": self = .replace
        case "next": self = .next
        case "tail": self = .tail
        default: return nil
        }
    }
}
#endif
