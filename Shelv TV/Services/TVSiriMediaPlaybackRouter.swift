import Intents
import OSLog
import UIKit

final class TVAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard let intent = userActivity.interaction?.intent as? INPlayMediaIntent else {
            return false
        }
        Task { @MainActor in
            await TVSiriMediaPlaybackRouter.handleForeground(intent)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handle intent: INIntent,
        completionHandler: @escaping (INIntentResponse) -> Void
    ) {
        guard let playIntent = intent as? INPlayMediaIntent else {
            completionHandler(INIntentResponse())
            return
        }
        Task { @MainActor in
            let code = await TVSiriMediaPlaybackRouter.handle(playIntent)
            completionHandler(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
    }
}

@MainActor
enum TVSiriMediaPlaybackRouter {
    private static let logger = Logger(
        subsystem: "ch.vkugler.Shelv",
        category: "TVSiriMedia"
    )
    private static var lastForegroundRequest: (request: ShelvTVSiriRequest, date: Date)?

    static func handleForeground(_ intent: INPlayMediaIntent) async {
        let request = ShelvTVSiriRequest(intent: intent)
        if let previous = lastForegroundRequest,
           previous.request == request,
           Date().timeIntervalSince(previous.date) < 2 {
            return
        }
        lastForegroundRequest = (request, Date())
        _ = await handle(request)
    }

    static func handle(_ intent: INPlayMediaIntent) async -> INPlayMediaIntentResponseCode {
        await handle(ShelvTVSiriRequest(intent: intent))
    }

    private static func handle(
        _ request: ShelvTVSiriRequest
    ) async -> INPlayMediaIntentResponseCode {
        do {
            try await perform(request)
            logger.notice("tvOS Siri media playback completed type=\(request.mediaTypeRawValue, privacy: .public)")
            return .success
        } catch let error as ShortcutPlaybackError {
            logger.error("tvOS Siri media playback failed error=\(String(describing: error), privacy: .public)")
            switch error {
            case .notFound, .noPlayableContent, .instantMixUnavailable:
                return .failureNoUnplayedContent
            case .noActiveServer:
                return .failureRequiringAppLaunch
            default:
                return .failure
            }
        } catch {
            logger.error("tvOS Siri media playback failed error=\(String(describing: error), privacy: .public)")
            return .failure
        }
    }

    private static func perform(_ request: ShelvTVSiriRequest) async throws {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            if request.mediaReferenceRawValue == INMediaReference.currentlyPlaying.rawValue {
                if !AudioPlayerService.shared.isPlaying {
                    try await ShelvSystemIntentPlaybackService.shared.execute(.playPause)
                }
                return
            }
            switch INMediaSortOrder(rawValue: request.sortOrderRawValue) ?? .unknown {
            case .newest:
                try await ShelvSystemIntentPlaybackService.shared.execute(.mix(.newest))
                return
            case .best, .popular, .trending, .recommended:
                try await ShelvSystemIntentPlaybackService.shared.execute(.mix(.frequent))
                return
            default:
                if request.sortOrderRawValue != INMediaSortOrder.unknown.rawValue {
                    throw ShortcutPlaybackError.notFound
                }
                if request.playShuffled || request.mediaType == .music {
                    try await ShelvSystemIntentPlaybackService.shared.execute(.mix(.shuffleAll))
                    return
                }
                throw ShortcutPlaybackError.notFound
            }
        }

        // Siri may encode a named mix either as a native sort order or as the
        // media name. Both representations must execute the same Shelv action.
        if let mix = ShelvSmartMixIntentVocabulary.smartMix(for: query) {
            try await ShelvSystemIntentPlaybackService.shared.execute(.mix(mix))
            return
        }

        let allowedKinds = allowedKinds(for: request.mediaType)
        let candidates = try await ShelvIntentCatalog.shared.items(
            matching: query,
            limit: 20,
            requiresExplicitRadio: false,
            allowedKinds: allowedKinds
        )
        let matches = ShelvIntentCatalog.deterministicPlaybackMatches(
            candidates,
            query: query
        )
        guard let match = matches.first else { throw ShortcutPlaybackError.notFound }

        if isInstantMixType(request.mediaType) {
            try await ShelvSystemIntentPlaybackService.shared.execute(.instantMix(match.reference))
            return
        }

        let order: ShortcutPlaybackOrder = request.playShuffled ? .shuffled : .inOrder
        let placement: ShortcutQueuePlacement
        switch INPlaybackQueueLocation(rawValue: request.playbackQueueLocationRawValue) ?? .unknown {
        case .next: placement = .next
        case .later: placement = .tail
        default: placement = .replace
        }
        let repeats = request.playbackRepeatModeRawValue != INPlaybackRepeatMode.none.rawValue
            && request.playbackRepeatModeRawValue != INPlaybackRepeatMode.unknown.rawValue
        try await ShelvSystemIntentPlaybackService.shared.play(
            match.reference,
            order: order,
            placement: placement,
            repeats: repeats
        )
    }

    private static func allowedKinds(
        for mediaType: INMediaItemType
    ) -> Set<ShortcutPlayableKind> {
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

    private static func isInstantMixType(_ mediaType: INMediaItemType) -> Bool {
        switch mediaType {
        case .musicStation, .station, .algorithmicRadioStation: true
        default: false
        }
    }
}
