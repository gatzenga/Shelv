import Foundation
import OSLog

nonisolated enum ShortcutPlayableKind: String, CaseIterable, Hashable, Sendable {
    case song
    case album
    case artist
    case playlist
    case radio

    /// Tie-break order for search results that match a query equally well
    /// under different kinds (e.g. a single-track album sharing its song's
    /// title). Ordered so the song wins instead of raw-value alphabetical
    /// order, which put "album" ahead of "song".
    var tieBreakPriority: Int {
        switch self {
        case .song: 0
        case .playlist: 1
        case .album: 2
        case .artist: 3
        case .radio: 4
        }
    }
}

nonisolated enum ShortcutPlaybackOrder: String, CaseIterable, Hashable, Sendable {
    case inOrder
    case shuffled
}

nonisolated enum ShortcutSmartMix: String, CaseIterable, Hashable, Sendable {
    case newest
    case frequent
    case recent
    case shuffleAll
}

nonisolated enum ShortcutDownloadsMode: String, CaseIterable, Hashable, Sendable {
    case all
    case shuffled
    case newest
}

nonisolated enum ShortcutQueuePlacement: Hashable, Sendable {
    case replace
    case next
    case tail
}

/// How long the caller may take to answer the system before its own watchdog
/// fires. Streaming a track from a self-hosted server regularly takes longer
/// than that, so the answer deadline is deliberately separate from the work
/// itself: playback keeps running after the deadline instead of being aborted.
nonisolated enum ShortcutIntentBudget: Hashable, Sendable {
    /// Classic SiriKit allows roughly ten seconds per resolve/confirm/handle
    /// phase. Answering later makes Siri announce a failure over music that is
    /// already on its way, which is exactly the wrong feedback.
    case siriKit
    /// App Intents allow roughly thirty seconds per `perform()`.
    case appIntent

    var responseDeadline: Duration {
        switch self {
        case .siriKit: .seconds(7)
        case .appIntent: .seconds(22)
        }
    }

    var diagnosticName: String {
        switch self {
        case .siriKit: "siriKit"
        case .appIntent: "appIntent"
        }
    }
}

nonisolated protocol ShortcutRemoteErrorClassifying: Error {
    var shortcutPlaybackError: ShortcutPlaybackError { get }
}

nonisolated struct ShortcutPlayableReference: Hashable, Sendable {
    let serverConfigID: String
    let kind: ShortcutPlayableKind
    let contentID: String

    var identifier: String {
        let encodedID = Data(contentID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(serverConfigID)|\(kind.rawValue)|\(encodedID)"
    }

    init(serverConfigID: String, kind: ShortcutPlayableKind, contentID: String) {
        self.serverConfigID = serverConfigID
        self.kind = kind
        self.contentID = contentID
    }

    init?(identifier: String) {
        let components = identifier.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 3,
              let kind = ShortcutPlayableKind(rawValue: String(components[1]))
        else { return nil }

        var encoded = String(components[2])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded),
              let contentID = String(data: data, encoding: .utf8)
        else { return nil }

        self.init(
            serverConfigID: String(components[0]),
            kind: kind,
            contentID: contentID
        )
    }
}

nonisolated enum ShortcutPlaybackCommand: Hashable, Sendable {
    case playable(ShortcutPlayableReference, order: ShortcutPlaybackOrder)
    case mix(ShortcutSmartMix)
    case downloads(ShortcutDownloadsMode)
    case instantMix(ShortcutPlayableReference)
    case playPause
    case next
    case previous

    var diagnosticAction: String {
        switch self {
        case .playable(_, let order): order == .shuffled ? "playable.shuffle" : "playable.play"
        case .mix(let mix): "mix.\(mix.rawValue)"
        case .downloads(let mode): "downloads.\(mode.rawValue)"
        case .instantMix: "instantMix"
        case .playPause: "playPause"
        case .next: "next"
        case .previous: "previous"
        }
    }

    var diagnosticReference: ShortcutPlayableReference? {
        switch self {
        case .playable(let reference, _), .instantMix(let reference): reference
        case .mix, .downloads, .playPause, .next, .previous: nil
        }
    }
}

nonisolated enum ShelvIntentDiagnostics {
    private static let logger = Logger(subsystem: "ch.vkugler.Shelv", category: "AppIntents")

    static func received(route: String) {
        logger.notice("System intent received route=\(route, privacy: .public)")
    }

    static func siriKitConfirmed(hasServer: Bool) {
        logger.notice(
            "SiriKit confirm hasServer=\(hasServer, privacy: .public) code=\(hasServer ? "ready" : "failureRequiringAppLaunch", privacy: .public)"
        )
    }

    /// What Siri actually asked for, after Shelv flattened the media search into
    /// one catalog query. The first thing to check when a spoken request fails.
    static func siriKitRequest(
        mediaType: Int,
        query: String,
        artist: String?,
        album: String?
    ) {
        #if DEBUG
        logger.notice(
            "SiriKit request mediaType=\(mediaType, privacy: .public) query=\(query, privacy: .public) artist=\(artist ?? "none", privacy: .public) album=\(album ?? "none", privacy: .public)"
        )
        #else
        logger.notice(
            "SiriKit request mediaType=\(mediaType, privacy: .public) queryLength=\(query.count, privacy: .public) hasArtist=\(artist != nil, privacy: .public)"
        )
        #endif
    }

    static func siriKitResolved(candidateCount: Int, matchCount: Int, chosen: String?) {
        #if DEBUG
        logger.notice(
            "SiriKit resolved candidates=\(candidateCount, privacy: .public) matches=\(matchCount, privacy: .public) chosen=\(chosen ?? "none", privacy: .public)"
        )
        #else
        logger.notice(
            "SiriKit resolved candidates=\(candidateCount, privacy: .public) matches=\(matchCount, privacy: .public)"
        )
        #endif
    }

    static func began(action: String, reference: ShortcutPlayableReference? = nil) {
        logger.notice(
            "Intent began action=\(action, privacy: .public) kind=\(reference?.kind.rawValue ?? "none", privacy: .public) item=\(reference?.contentID ?? "none", privacy: .private(mask: .hash))"
        )
    }

    static func completed(action: String) {
        logger.notice("Intent completed action=\(action, privacy: .public)")
    }

    static func failed(action: String, error: ShortcutPlaybackError) {
        logger.error(
            "Intent failed action=\(action, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
    }

    static func answeredWhileStarting(action: String, budget: ShortcutIntentBudget) {
        logger.notice(
            "Intent answered before playback confirmed action=\(action, privacy: .public) budget=\(budget.diagnosticName, privacy: .public)"
        )
    }

    static func catalogResolved(queryLength: Int, resultCount: Int) {
        logger.debug(
            "Catalog resolved queryLength=\(queryLength, privacy: .public) resultCount=\(resultCount, privacy: .public)"
        )
    }

    static func catalogRemoteFailed(operation: String, error: Error) {
        logger.error(
            "Catalog remote request failed operation=\(operation, privacy: .public) error=\(String(describing: error), privacy: .private(mask: .hash))"
        )
    }

    static func catalogRemoteTimedOut(operation: String) {
        logger.error(
            "Catalog remote request timed out operation=\(operation, privacy: .public)"
        )
    }

    static func audioSearchBegan(criteria: String) {
        logger.notice("Audio search began criteria=\(criteria, privacy: .public)")
    }

    static func audioSearchInput(criteria: String, description: String) {
        #if DEBUG
        logger.notice(
            "Audio search input criteria=\(criteria, privacy: .public) value=\(description, privacy: .public)"
        )
        #else
        logger.notice(
            "Audio search input criteria=\(criteria, privacy: .public) descriptionLength=\(description.count, privacy: .public)"
        )
        #endif
    }

    static func audioSearchQuery(_ query: String) {
        #if DEBUG
        logger.notice(
            "Audio search query value=\(query, privacy: .public) length=\(query.count, privacy: .public)"
        )
        #else
        logger.notice("Audio search query length=\(query.count, privacy: .public)")
        #endif
    }

    static func audioSearchResult(
        index: Int,
        kind: String,
        identifier: String,
        title: String,
        artist: String?,
        referenceValid: Bool
    ) {
        #if DEBUG
        logger.notice(
            "Audio search result index=\(index, privacy: .public) kind=\(kind, privacy: .public) id=\(identifier, privacy: .public) idLength=\(identifier.count, privacy: .public) title=\(title, privacy: .public) artist=\(artist ?? "none", privacy: .public) referenceValid=\(referenceValid, privacy: .public)"
        )
        #else
        logger.notice(
            "Audio search result index=\(index, privacy: .public) kind=\(kind, privacy: .public) id=\(identifier, privacy: .private(mask: .hash)) idLength=\(identifier.count, privacy: .public) title=\(title, privacy: .private(mask: .hash)) referenceValid=\(referenceValid, privacy: .public)"
        )
        #endif
    }

    static func audioIntentEntity(
        kind: String,
        identifier: String,
        title: String,
        referenceValid: Bool
    ) {
        #if DEBUG
        logger.notice(
            "Play audio entity received kind=\(kind, privacy: .public) id=\(identifier, privacy: .public) title=\(title, privacy: .public) referenceValid=\(referenceValid, privacy: .public)"
        )
        #else
        logger.notice(
            "Play audio entity received kind=\(kind, privacy: .public) id=\(identifier, privacy: .private(mask: .hash)) title=\(title, privacy: .private(mask: .hash)) referenceValid=\(referenceValid, privacy: .public)"
        )
        #endif
    }

    static func entityLookupBegan(
        identifierCount: Int,
        parsedCount: Int
    ) {
        logger.notice(
            "Audio entity lookup began identifiers=\(identifierCount, privacy: .public) parsed=\(parsedCount, privacy: .public)"
        )
    }

    static func entityLookupCompleted(
        requestedCount: Int,
        matchingServerCount: Int,
        resultCount: Int
    ) {
        logger.notice(
            "Audio entity lookup completed requested=\(requestedCount, privacy: .public) matchingServer=\(matchingServerCount, privacy: .public) results=\(resultCount, privacy: .public)"
        )
    }

    static func entityLookupFailed(error: Error) {
        logger.error(
            "Audio entity lookup failed error=\(String(describing: error), privacy: .private(mask: .hash))"
        )
    }

    static func audioSearchCompleted(criteria: String, route: String, resultCount: Int) {
        logger.notice(
            "Audio search completed criteria=\(criteria, privacy: .public) route=\(route, privacy: .public) resultCount=\(resultCount, privacy: .public)"
        )
    }

    static func audioSearchFailed(criteria: String, error: Error) {
        logger.error(
            "Audio search failed criteria=\(criteria, privacy: .public) error=\(String(describing: error), privacy: .private(mask: .hash))"
        )
    }

    static func queueWarmed(kind: ShortcutPlayableKind, trackCount: Int) {
        logger.notice(
            "Queue warmed kind=\(kind.rawValue, privacy: .public) trackCount=\(trackCount, privacy: .public)"
        )
    }

    static func warmedQueueUsed(trackCount: Int) {
        logger.notice(
            "Warmed queue reused trackCount=\(trackCount, privacy: .public)"
        )
    }

    static func libraryEdit(action: String, kind: ShortcutPlayableKind, count: Int) {
        logger.notice(
            "Library edit action=\(action, privacy: .public) kind=\(kind.rawValue, privacy: .public) count=\(count, privacy: .public)"
        )
    }

    static func instantMixBuilt(kind: ShortcutPlayableKind, trackCount: Int) {
        logger.notice(
            "Instant Mix built kind=\(kind.rawValue, privacy: .public) trackCount=\(trackCount, privacy: .public)"
        )
    }

    static func instantMixPlaybackConfirmed(trackCount: Int) {
        logger.notice(
            "Instant Mix playback confirmed trackCount=\(trackCount, privacy: .public)"
        )
    }
}

nonisolated enum ShortcutPlaybackError: Error, Equatable, Sendable,
    CustomLocalizedStringResourceConvertible, LocalizedError {
    case noActiveServer
    case serverChanged
    case noNetwork
    case notFound
    case noPlayableContent
    case instantMixUnavailable
    case unavailableOffline
    case radioUnavailableOffline
    case unsupportedQueueOperation
    case unsupportedLibraryEdit
    case alreadyInPlaylist
    case playbackFailed
    case playbackTimedOut
    case cancelled

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noActiveServer: return "shortcut_error_no_server"
        case .serverChanged: return "shortcut_error_server_changed"
        case .noNetwork: return "shortcut_error_no_network"
        case .notFound: return "shortcut_error_not_found"
        case .noPlayableContent: return "shortcut_error_no_content"
        case .instantMixUnavailable: return "shortcut_error_instant_mix_unavailable"
        case .unavailableOffline: return "shortcut_error_unavailable_offline"
        case .radioUnavailableOffline: return "shortcut_error_radio_offline"
        case .unsupportedQueueOperation: return "shortcut_error_unsupported_queue_operation"
        case .unsupportedLibraryEdit: return "shortcut_error_unsupported_library_edit"
        case .alreadyInPlaylist: return "shortcut_error_already_in_playlist"
        case .playbackFailed: return "shortcut_error_playback_failed"
        case .playbackTimedOut: return "shortcut_error_playback_timed_out"
        case .cancelled: return "shortcut_error_cancelled"
        }
    }

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }

    static func remoteFailure(_ error: Error) -> ShortcutPlaybackError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .noNetwork
        }
        return (error as? ShortcutRemoteErrorClassifying)?.shortcutPlaybackError
            ?? .playbackFailed
    }
}

nonisolated enum ShelvShortcutDestination: String, Sendable {
    case discover
    case library
    case search
    case nowPlaying
}
