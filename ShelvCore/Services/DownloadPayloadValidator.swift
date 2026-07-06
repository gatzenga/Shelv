import AVFoundation
import Foundation

nonisolated struct DownloadPayloadValidation: Sendable {
    let fileExtension: String?
    let contentType: String?
}

nonisolated enum DownloadPayloadValidationError: LocalizedError, Equatable {
    case httpStatus(Int)
    case emptyFile
    case rejectedMime(String)
    case unreadableFile(String)
    case unsupportedPayload(mimeType: String?, fileExtension: String?)
    case unplayableAudio(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return "Download returned HTTP \(status)"
        case .emptyFile:
            return "Downloaded file is empty"
        case .rejectedMime(let mime):
            return "Downloaded response is not audio (\(mime))"
        case .unreadableFile(let message):
            return "Downloaded file could not be read: \(message)"
        case .unsupportedPayload(let mimeType, let fileExtension):
            let mime = mimeType ?? "unknown MIME"
            let ext = fileExtension ?? "unknown extension"
            return "Downloaded payload does not look like audio (\(mime), \(ext))"
        case .unplayableAudio(let reason):
            return "Downloaded audio could not be opened: \(reason)"
        }
    }
}

nonisolated enum DownloadPayloadValidator {
    private struct AudioKind {
        let fileExtension: String
    }

    static func validate(fileURL: URL,
                         byteSize: Int64,
                         statusCode: Int?,
                         mimeType: String?,
                         fallbackFileExtension: String?) async throws -> DownloadPayloadValidation {
        if let statusCode, !(200...299).contains(statusCode) {
            throw DownloadPayloadValidationError.httpStatus(statusCode)
        }

        let actualBytes = byteSize > 0 ? byteSize : fileSize(at: fileURL)
        guard actualBytes > 0 else {
            throw DownloadPayloadValidationError.emptyFile
        }

        let normalizedMime = normalize(mimeType: mimeType)
        if let normalizedMime, isRejectedMime(normalizedMime) {
            throw DownloadPayloadValidationError.rejectedMime(normalizedMime)
        }

        let header = try headerData(from: fileURL)
        let sniffedKind = sniffAudioKind(header: header)
        let mimeExtension = TranscodingPolicy.extensionFor(mimeType: normalizedMime)
        let fallbackExtension = normalize(fileExtension: fallbackFileExtension)
        let resolvedExtension = sniffedKind?.fileExtension ?? mimeExtension ?? fallbackExtension

        if sniffedKind == nil {
            guard acceptsAmbiguousMime(normalizedMime) else {
                throw DownloadPayloadValidationError.unsupportedPayload(
                    mimeType: normalizedMime,
                    fileExtension: fallbackExtension
                )
            }

            guard await canOpenWithAVFoundation(fileURL) else {
                throw DownloadPayloadValidationError.unsupportedPayload(
                    mimeType: normalizedMime,
                    fileExtension: fallbackExtension
                )
            }
        }

        return DownloadPayloadValidation(
            fileExtension: resolvedExtension,
            contentType: normalizedMime
        )
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
    }

    private static func headerData(from url: URL) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: 4096) ?? Data()
        } catch {
            throw DownloadPayloadValidationError.unreadableFile(error.localizedDescription)
        }
    }

    private static func normalize(mimeType: String?) -> String? {
        let normalized = mimeType?
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func normalize(fileExtension: String?) -> String? {
        let normalized = fileExtension?
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func isRejectedMime(_ mime: String) -> Bool {
        if mime.hasPrefix("audio/") { return false }
        if mime == "application/ogg" || mime == "application/octet-stream" || mime == "binary/octet-stream" {
            return false
        }
        if mime.hasPrefix("text/") { return true }
        switch mime {
        case "application/json",
             "application/problem+json",
             "application/xml",
             "application/xhtml+xml",
             "application/html",
             "image/jpeg",
             "image/png",
             "image/gif",
             "image/webp":
            return true
        default:
            return false
        }
    }

    private static func acceptsAmbiguousMime(_ mime: String?) -> Bool {
        guard let mime else { return true }
        if mime.hasPrefix("audio/") { return true }
        switch mime {
        case "application/octet-stream",
             "binary/octet-stream",
             "application/ogg",
             "application/x-download",
             "application/force-download":
            return true
        default:
            return false
        }
    }

    private static func sniffAudioKind(header: Data) -> AudioKind? {
        guard !header.isEmpty else { return nil }
        let bytes = [UInt8](header.prefix(16))

        if starts(with: "ID3", bytes: bytes) || looksLikeMP3Frame(bytes) {
            return AudioKind(fileExtension: "mp3")
        }
        if starts(with: "fLaC", bytes: bytes) {
            return AudioKind(fileExtension: "flac")
        }
        if starts(with: "OggS", bytes: bytes) {
            return AudioKind(fileExtension: "opus")
        }
        if starts(with: "RIFF", bytes: bytes), bytes.count >= 12, starts(with: "WAVE", bytes: Array(bytes[8..<12])) {
            return AudioKind(fileExtension: "wav")
        }
        if bytes.count >= 12, starts(with: "ftyp", bytes: Array(bytes[4..<8])) {
            return AudioKind(fileExtension: "m4a")
        }
        if looksLikeADTS(bytes) {
            return AudioKind(fileExtension: "aac")
        }
        if starts(with: "FORM", bytes: bytes), bytes.count >= 12, starts(with: "AIFF", bytes: Array(bytes[8..<12])) {
            return AudioKind(fileExtension: "aiff")
        }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return AudioKind(fileExtension: "webm")
        }
        return nil
    }

    private static func starts(with ascii: String, bytes: [UInt8]) -> Bool {
        let prefix = Array(ascii.utf8)
        return bytes.starts(with: prefix)
    }

    private static func looksLikeMP3Frame(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 && !looksLikeADTS(bytes)
    }

    private static func looksLikeADTS(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        return bytes[0] == 0xFF && (bytes[1] & 0xF6) == 0xF0
    }

    private static func canOpenWithAVFoundation(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else { return false }
            if let duration = try? await asset.load(.duration) {
                let seconds = duration.seconds
                return seconds.isFinite && seconds >= 0
            }
            return true
        } catch {
            return false
        }
    }
}
