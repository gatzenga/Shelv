import Foundation
import OSLog

nonisolated enum ShortcutPlayableKind: String, CaseIterable, Hashable, Sendable {
    case song
    case album
    case artist
    case playlist
    case radio
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

    static func catalogResolved(queryLength: Int, resultCount: Int) {
        logger.debug(
            "Catalog resolved queryLength=\(queryLength, privacy: .public) resultCount=\(resultCount, privacy: .public)"
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
    case unavailableOffline
    case radioUnavailableOffline
    case unsupportedQueueOperation
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
        case .unavailableOffline: return "shortcut_error_unavailable_offline"
        case .radioUnavailableOffline: return "shortcut_error_radio_offline"
        case .unsupportedQueueOperation: return "shortcut_error_unsupported_queue_operation"
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
    case recap
    case nowPlaying
}
