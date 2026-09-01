import Foundation

nonisolated enum TranscodingCodec: String, CaseIterable, Identifiable, Codable {
    case raw, opus, mp3
    var id: String { rawValue }
    var label: String {
        switch self {
        case .raw:  return String(localized: "original")
        case .opus: return "Opus"
        case .mp3:  return "MP3"
        }
    }
    nonisolated var fileExtension: String {
        switch self {
        case .raw:  return ""
        case .opus: return "opus"
        case .mp3:  return "mp3"
        }
    }

    /// AAC bleibt bewusst deaktiviert: Navidrome liefert es nicht zuverlässig in
    /// einem für AVPlayer sauber nutzbaren Container.
    static var streamingOptions: [TranscodingCodec] { [.raw, .opus, .mp3] }
    static var downloadOptions: [TranscodingCodec] { [.raw, .opus, .mp3] }
}

nonisolated enum TranscodingBitrate: Int, CaseIterable, Identifiable {
    case k64 = 64, k96 = 96, k128 = 128, k192 = 192, k256 = 256, k320 = 320
    var id: Int { rawValue }
    var label: String { "\(rawValue) kbps" }
}

nonisolated struct TranscodingPolicy {
    /// Written by `ServerStore` whenever the active server or its URL slot
    /// changes, so the streaming policy can tell home from away.
    static let usingSecondaryURLKey = "activeServerUsesSecondaryURL"
    /// Whether the active server holds a secondary URL at all. Without one
    /// there is no away slot, so nothing to exempt.
    static let hasSecondaryURLKey = "activeServerHasSecondaryURL"

    /// Liefert das gewünschte Stream-Format basierend auf aktuellem Netz.
    /// `nil` = kein Transcoding, Original wird angefordert.
    static func currentStreamFormat() -> (codec: TranscodingCodec, bitrate: Int)? {
        let profile = TranscodingProfileDecision.profile(
            isEnabled: UserDefaults.standard.bool(forKey: "transcodingEnabled"),
            // Data-Saver (macOS-Menü): erzwingt das Cellular-Profil auch im WLAN.
            // Auf iOS ist der Key nie gesetzt → kein Verhaltensunterschied.
            dataSaver: UserDefaults.standard.bool(forKey: "dataSaverEnabled"),
            isOnWifi: NetworkStatus.shared.isOnWifi,
            // Read as a plain flag rather than through SubsonicAPIService:
            // this file is compiled into ShelvTests, which does not include it.
            // ServerStore keeps the key in step with the active server.
            serverHasSecondaryURL: UserDefaults.standard.bool(forKey: TranscodingPolicy.hasSecondaryURLKey),
            isOnPrimaryServerURL: !UserDefaults.standard.bool(forKey: TranscodingPolicy.usingSecondaryURLKey),
            exemptsPrimaryServerURL: UserDefaults.standard.bool(forKey: "transcodingPrimaryURLExempt")
        )

        let codecKey: String
        let bitrateKey: String
        switch profile {
        case .original:
            return nil
        case .wifi:
            codecKey = "transcodingWifiCodec"
            bitrateKey = "transcodingWifiBitrate"
        case .cellular:
            codecKey = "transcodingCellularCodec"
            bitrateKey = "transcodingCellularBitrate"
        }

        let codecRaw = UserDefaults.standard.string(forKey: codecKey) ?? "raw"
        guard let codec = TranscodingCodec(rawValue: codecRaw), codec != .raw else { return nil }
        let rate = UserDefaults.standard.integer(forKey: bitrateKey)
        return (codec, rate > 0 ? rate : 192)
    }

    /// Liefert das gewünschte Download-Format. `nil` = Original (`/download` Endpoint).
    static func currentDownloadFormat() -> (codec: TranscodingCodec, bitrate: Int)? {
        let codecRaw = UserDefaults.standard.string(forKey: "transcodingDownloadCodec") ?? "raw"
        guard let codec = TranscodingCodec(rawValue: codecRaw), codec != .raw else { return nil }
        let rate = UserDefaults.standard.integer(forKey: "transcodingDownloadBitrate")
        return (codec, rate > 0 ? rate : 192)
    }

    /// Mapping HTTP `Content-Type` → Datei-Extension. Wird beim Speichern eines Downloads
    /// genutzt damit ein Server-seitiger Fallback (z. B. Original liefern statt Transcoding)
    /// trotzdem mit der korrekten Extension landet.
    static func extensionFor(mimeType: String?) -> String? {
        let mime = mimeType?
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let mime, !mime.isEmpty else { return nil }
        switch mime {
        case "audio/mpeg", "audio/mp3":          return "mp3"
        case "audio/aac", "audio/aacp":          return "aac"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/ogg", "audio/opus", "audio/x-opus+ogg", "application/ogg": return "opus"
        case "audio/flac", "audio/x-flac":       return "flac"
        case "audio/wav", "audio/x-wav":         return "wav"
        case "audio/webm":                        return "webm"
        default:                                  return nil
        }
    }
}
