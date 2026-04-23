import Foundation

enum TranscodingCodec: String, CaseIterable, Identifiable {
    case raw, opus, mp3, aac
    var id: String { rawValue }
    var label: String {
        switch self {
        case .raw:  return tr("Original", "Original")
        case .opus: return "Opus"
        case .mp3:  return "MP3"
        case .aac:  return "AAC"
        }
    }
    nonisolated var fileExtension: String {
        switch self {
        case .raw:  return ""
        case .opus: return "opus"
        case .mp3:  return "mp3"
        case .aac:  return "m4a"
        }
    }

    /// AAC funktioniert mit Navidrome live-Transcoding + AVPlayer nicht zuverlässig
    /// (kein Container der HTTP-streamable ist), daher nur für Downloads.
    static var streamingOptions: [TranscodingCodec] { [.raw, .opus, .mp3] }
    static var downloadOptions: [TranscodingCodec] { [.raw, .opus, .mp3] }
}

enum TranscodingBitrate: Int, CaseIterable, Identifiable {
    case k64 = 64, k96 = 96, k128 = 128, k192 = 192, k256 = 256, k320 = 320
    var id: Int { rawValue }
    var label: String { "\(rawValue) kbps" }
}

struct TranscodingPolicy {
    /// Liefert das gewünschte Stream-Format basierend auf aktuellem Netz.
    /// `nil` = kein Transcoding, Original wird angefordert.
    static func currentStreamFormat() -> (codec: TranscodingCodec, bitrate: Int)? {
        guard UserDefaults.standard.bool(forKey: "transcodingEnabled") else { return nil }
        let isWifi = NetworkStatus.shared.isOnWifi
        let codecKey = isWifi ? "transcodingWifiCodec" : "transcodingCellularCodec"
        let bitrateKey = isWifi ? "transcodingWifiBitrate" : "transcodingCellularBitrate"
        let codecRaw = UserDefaults.standard.string(forKey: codecKey) ?? "raw"
        guard let codec = TranscodingCodec(rawValue: codecRaw), codec != .raw else { return nil }
        let rate = UserDefaults.standard.integer(forKey: bitrateKey)
        return (codec, rate > 0 ? rate : 192)
    }

    /// Liefert das gewünschte Download-Format. `nil` = Original (`/download` Endpoint).
    static func currentDownloadFormat() -> (codec: TranscodingCodec, bitrate: Int)? {
        guard UserDefaults.standard.bool(forKey: "transcodingEnabled") else { return nil }
        let codecRaw = UserDefaults.standard.string(forKey: "transcodingDownloadCodec") ?? "raw"
        guard let codec = TranscodingCodec(rawValue: codecRaw), codec != .raw else { return nil }
        let rate = UserDefaults.standard.integer(forKey: "transcodingDownloadBitrate")
        return (codec, rate > 0 ? rate : 192)
    }

    /// Mapping HTTP `Content-Type` → Datei-Extension. Wird beim Speichern eines Downloads
    /// genutzt damit ein Server-seitiger Fallback (z. B. Original liefern statt Transcoding)
    /// trotzdem mit der korrekten Extension landet.
    static func extensionFor(mimeType: String?) -> String? {
        guard let mime = mimeType?.lowercased() else { return nil }
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
