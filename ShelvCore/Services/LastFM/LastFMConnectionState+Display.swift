import Foundation

extension LastFMConnectionState {
    nonisolated var displayText: String {
        switch self {
        case .notConfigured:
            return String(localized: "lastfm_status_not_configured")
        case .notConnected:
            return String(localized: "lastfm_status_not_connected")
        case .checking:
            return String(localized: "lastfm_status_checking")
        case .connected(let username):
            return String(format: String(localized: "lastfm_status_connected_format"), username)
        case .failed(let problem):
            switch problem {
            case .invalidAPIKey: return String(localized: "lastfm_error_api_key")
            case .invalidSecret: return String(localized: "lastfm_error_secret")
            case .accessRevoked: return String(localized: "lastfm_error_revoked")
            case .authorizationIncomplete: return String(localized: "lastfm_error_not_authorized")
            case .unreachable: return String(localized: "lastfm_error_unreachable")
            case .other(let message): return message
            }
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .notConfigured, .notConnected: return "circle.dashed"
        }
    }

    nonisolated var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
