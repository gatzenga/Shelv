import Combine
import Foundation

final class StreamCacheStatus: ObservableObject {
    static let shared = StreamCacheStatus()

    @Published private(set) var activeSongIds: Set<String> = []
    @Published private(set) var cachedSongIds: Set<String> = []

    private init() {}

    func markActive(_ songId: String) {
        activeSongIds.insert(songId)
    }

    func markCached(_ songId: String) {
        activeSongIds.remove(songId)
        cachedSongIds.insert(songId)
    }

    func remove(_ songId: String) {
        activeSongIds.remove(songId)
        cachedSongIds.remove(songId)
    }

    func removeAll() {
        activeSongIds.removeAll()
        cachedSongIds.removeAll()
    }
}

actor StreamCacheService {
    static let shared = StreamCacheService()
    private init() {}

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var activeFormats: [String: ActualStreamFormat] = [:]
    private var cachedURLs: [String: URL] = [:]
    private var cachedFormats: [String: ActualStreamFormat] = [:]
    private static let cacheFileExtensions: Set<String> = [
        "aac", "aif", "aiff", "audio", "flac", "m4a", "mp3", "ogg", "opus", "wav", "webm"
    ]

    private static func tempURL(for songId: String, ext: String = "") -> URL {
        let safeSongId = songId.pathSafeComponent
        let name = ext.isEmpty ? "shelv_stream_\(safeSongId)" : "shelv_stream_\(safeSongId).\(ext)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private static func fileExtension(for codecLabel: String) -> String {
        switch codecLabel.uppercased() {
        case "MP3":          return "mp3"
        case "OPUS":         return "opus"
        case "AAC":          return "m4a"
        case "FLAC":         return "flac"
        case "OGG":          return "ogg"
        case "WAV":          return "wav"
        case "M4A":          return "m4a"
        case "AIFF", "AIF": return "aiff"
        default:             return "audio"
        }
    }

    private static func normalizedCodecLabel(_ label: String) -> String {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "M4A": return "AAC"
        default:    return label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }

    private static func deliveredFormat(from response: HTTPURLResponse,
                                        requested: ActualStreamFormat) -> (format: ActualStreamFormat, fileExtension: String) {
        guard let ext = TranscodingPolicy.extensionFor(mimeType: response.mimeType) else {
            return (requested, fileExtension(for: requested.codecLabel))
        }
        let codec = ActualStreamFormat.codecLabel(forMime: response.mimeType)
        let requestedCodec = normalizedCodecLabel(requested.codecLabel)
        let deliveredCodec = normalizedCodecLabel(codec)
        let bitrate = deliveredCodec == requestedCodec ? requested.bitrateKbps : nil
        return (ActualStreamFormat(codecLabel: codec, bitrateKbps: bitrate), ext)
    }

    private static func didFormatChange(requested: ActualStreamFormat, delivered: ActualStreamFormat) -> Bool {
        let requestedCodec = normalizedCodecLabel(requested.codecLabel)
        let deliveredCodec = normalizedCodecLabel(delivered.codecLabel)
        return requestedCodec != deliveredCodec || requested.bitrateKbps != delivered.bitrateKbps
    }

    func localURL(for songId: String) -> URL? {
        cachedURLs[songId]
    }

    func cachedFormat(for songId: String) -> ActualStreamFormat? {
        cachedFormats[songId]
    }

    func prefetch(songId: String, url: URL, codec: String, bitrate: Int, songTitle: String = "") {
        if !songTitle.isEmpty { StreamCacheLog.register(songId: songId, title: songTitle) }
        if cachedURLs[songId] != nil {
            StreamCacheLog.log(songId: songId, message: "Already cached – skipped")
            return
        }
        if activeTasks[songId] != nil {
            StreamCacheLog.log(songId: songId, message: "Already downloading – skipped")
            return
        }
        let desc = bitrate > 0 ? "\(codec.uppercased()) · \(bitrate) kbps" : codec.uppercased()
        StreamCacheLog.log(songId: songId, message: "Prefetch started (\(desc))")
        let format = ActualStreamFormat(codecLabel: codec.uppercased(), bitrateKbps: bitrate > 0 ? bitrate : nil)
        activeFormats[songId] = format
        publishActive(songId: songId)
        activeTasks[songId] = Task {
            await downloadWithRetry(songId: songId, url: url, format: format, maxAttempts: 3)
        }
    }

    func prefetchAndWait(songId: String, url: URL, codec: String, bitrate: Int, songTitle: String = "") async {
        if !songTitle.isEmpty { StreamCacheLog.register(songId: songId, title: songTitle) }
        if cachedURLs[songId] != nil {
            StreamCacheLog.log(songId: songId, message: "Already cached – skipped")
            return
        }
        if let task = activeTasks[songId] {
            StreamCacheLog.log(songId: songId, message: "Already downloading – waiting")
            await task.value
            return
        }
        let desc = bitrate > 0 ? "\(codec.uppercased()) · \(bitrate) kbps" : codec.uppercased()
        StreamCacheLog.log(songId: songId, message: "Prefetch started (\(desc))")
        let format = ActualStreamFormat(codecLabel: codec.uppercased(), bitrateKbps: bitrate > 0 ? bitrate : nil)
        activeFormats[songId] = format
        publishActive(songId: songId)
        let task = Task {
            await downloadWithRetry(songId: songId, url: url, format: format, maxAttempts: 3)
        }
        activeTasks[songId] = task
        await task.value
    }

    func cancel(songId: String) {
        let hadTask = activeTasks[songId] != nil
        let hadCache = cachedURLs[songId] != nil
        activeTasks[songId]?.cancel()
        activeTasks.removeValue(forKey: songId)
        let ext = activeFormats[songId].map { Self.fileExtension(for: $0.codecLabel) } ?? ""
        activeFormats.removeValue(forKey: songId)
        if let url = cachedURLs.removeValue(forKey: songId) {
            try? FileManager.default.removeItem(at: url)
        }
        cachedFormats.removeValue(forKey: songId)
        publishRemoved(songId: songId)
        if !ext.isEmpty {
            try? FileManager.default.removeItem(at: Self.tempURL(for: songId, ext: ext))
        }
        try? FileManager.default.removeItem(at: Self.tempURL(for: songId))
        if hadTask || hadCache {
            StreamCacheLog.log(songId: songId, message: "Removed")
        }
    }

    func cancelAll() {
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
        activeFormats.removeAll()
        for url in cachedURLs.values {
            try? FileManager.default.removeItem(at: url)
        }
        cachedURLs.removeAll()
        cachedFormats.removeAll()
        publishRemovedAll()
    }

    func cleanupOldFiles() {
        let tmp = FileManager.default.temporaryDirectory
        let activeSongIds = Set(activeTasks.keys.map(\.pathSafeComponent))
            .union(cachedURLs.keys.map(\.pathSafeComponent))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("shelv_stream_") {
            let songId = String(file.lastPathComponent.dropFirst("shelv_stream_".count))
            let candidates = songId.pathSafeComponentFileNameCandidates(knownFileExtensions: Self.cacheFileExtensions)
            guard activeSongIds.isDisjoint(with: candidates) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func downloadWithRetry(songId: String, url: URL, format: ActualStreamFormat, maxAttempts: Int) async {
        let requestedDest = Self.tempURL(for: songId, ext: Self.fileExtension(for: format.codecLabel))
        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            do {
                let (tmpURL, response) = try await URLSession.shared.download(from: url)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    StreamCacheLog.log(songId: songId, message: "Attempt \(attempt)/\(maxAttempts) – bad status")
                    if attempt < maxAttempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                    continue
                }
                let delivered = Self.deliveredFormat(from: http, requested: format)
                let dest = Self.tempURL(for: songId, ext: delivered.fileExtension)
                try? FileManager.default.removeItem(at: dest)
                if dest != requestedDest {
                    try? FileManager.default.removeItem(at: requestedDest)
                }
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                cachedFormats[songId] = delivered.format
                cachedURLs[songId] = dest
                activeFormats.removeValue(forKey: songId)
                activeTasks.removeValue(forKey: songId)
                publishCached(songId: songId)
                if Self.didFormatChange(requested: format, delivered: delivered.format) {
                    StreamCacheLog.log(songId: songId, message: "Cached as \(delivered.format.displayString) (requested \(format.displayString))")
                } else {
                    StreamCacheLog.log(songId: songId, message: "Cached ✓")
                }
                return
            } catch let urlError as URLError where urlError.code == .timedOut {
                StreamCacheLog.log(songId: songId, message: "Timeout – no retry")
                activeFormats.removeValue(forKey: songId)
                activeTasks.removeValue(forKey: songId)
                publishRemoved(songId: songId)
                return
            } catch {
                guard !Task.isCancelled else { return }
                StreamCacheLog.log(songId: songId, message: "Attempt \(attempt)/\(maxAttempts) – error: \(error.localizedDescription)")
                if attempt < maxAttempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        activeFormats.removeValue(forKey: songId)
        activeTasks.removeValue(forKey: songId)
        publishRemoved(songId: songId)
        StreamCacheLog.log(songId: songId, message: "All attempts failed")
    }

    private func publishActive(songId: String) {
        Task { @MainActor in StreamCacheStatus.shared.markActive(songId) }
    }

    private func publishCached(songId: String) {
        Task { @MainActor in StreamCacheStatus.shared.markCached(songId) }
    }

    private func publishRemoved(songId: String) {
        Task { @MainActor in StreamCacheStatus.shared.remove(songId) }
    }

    private func publishRemovedAll() {
        Task { @MainActor in StreamCacheStatus.shared.removeAll() }
    }
}
