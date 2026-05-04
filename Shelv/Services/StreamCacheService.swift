import Foundation

actor StreamCacheService {
    static let shared = StreamCacheService()
    private init() {}

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var activeFormats: [String: ActualStreamFormat] = [:]
    private var cachedURLs: [String: URL] = [:]
    private var cachedFormats: [String: ActualStreamFormat] = [:]

    // Fix 4: tempURL supports codec extension so AVPlayer recognises media type
    private static func tempURL(for songId: String, ext: String = "") -> URL {
        let name = ext.isEmpty ? "shelv_stream_\(songId)" : "shelv_stream_\(songId).\(ext)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    // Fix 4: derive file extension from codec label
    private static func fileExtension(for codecLabel: String) -> String {
        switch codecLabel.uppercased() {
        case "MP3":  return "mp3"
        case "OPUS": return "opus"
        case "AAC":  return "m4a"
        default:     return "audio"
        }
    }

    func localURL(for songId: String) -> URL? {
        cachedURLs[songId]
    }

    func cachedFormat(for songId: String) -> ActualStreamFormat? {
        cachedFormats[songId]
    }

    // Fix 3 + Fix 4: format passed into downloadWithRetry; activeFormats tracked for cancel
    func prefetch(songId: String, url: URL, codec: String, bitrate: Int) {
        guard activeTasks[songId] == nil, cachedURLs[songId] == nil else { return }
        let format = ActualStreamFormat(codecLabel: codec.uppercased(), bitrateKbps: bitrate)
        activeFormats[songId] = format
        activeTasks[songId] = Task {
            await downloadWithRetry(songId: songId, url: url, format: format, maxAttempts: 3)
        }
    }

    // Fix 4: cancel uses activeFormats to resolve extension; also removes extension-less fallback
    func cancel(songId: String) {
        activeTasks[songId]?.cancel()
        activeTasks.removeValue(forKey: songId)
        let ext = activeFormats[songId].map { Self.fileExtension(for: $0.codecLabel) } ?? ""
        activeFormats.removeValue(forKey: songId)
        cachedURLs.removeValue(forKey: songId)
        cachedFormats.removeValue(forKey: songId)
        try? FileManager.default.removeItem(at: Self.tempURL(for: songId, ext: ext))
        // Also remove extension-less file (legacy / fallback)
        try? FileManager.default.removeItem(at: Self.tempURL(for: songId))
    }

    // Fix 5: iterate values directly; Fix 4: remove files via cachedURLs (already have correct URL)
    func cancelAll() {
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
        activeFormats.removeAll()
        for url in cachedURLs.values {
            try? FileManager.default.removeItem(at: url)
        }
        cachedURLs.removeAll()
        cachedFormats.removeAll()
    }

    // Fix 1: skip active/cached files during cleanup
    func cleanupOldFiles() {
        let tmp = FileManager.default.temporaryDirectory
        let activeSongIds = Set(activeTasks.keys).union(cachedURLs.keys)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("shelv_stream_") {
            let songId = String(file.lastPathComponent.dropFirst("shelv_stream_".count))
            // Strip suffix if present (e.g. .opus, .mp3)
            let baseSongId = songId.components(separatedBy: ".").first ?? songId
            guard !activeSongIds.contains(baseSongId) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // Fix 3 + Fix 4: format parameter; cachedFormats set only on success; ext-aware dest
    // Fix 2: remove dest before moveItem to avoid POSIX error 17 (file exists)
    private func downloadWithRetry(songId: String, url: URL, format: ActualStreamFormat, maxAttempts: Int) async {
        let ext = Self.fileExtension(for: format.codecLabel)
        let dest = Self.tempURL(for: songId, ext: ext)
        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            do {
                let (tmpURL, response) = try await URLSession.shared.download(from: url)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    print("[StreamCache] Attempt \(attempt)/\(maxAttempts): bad status for \(songId)")
                    if attempt < maxAttempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                    continue
                }
                // Fix 2: remove destination before move so it never throws POSIX 17
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                // Fix 3: only record format once the file is safely in place
                cachedFormats[songId] = format
                cachedURLs[songId] = dest
                activeFormats.removeValue(forKey: songId)
                activeTasks.removeValue(forKey: songId)
                print("[StreamCache] Cached \(songId)")
                return
            } catch let urlError as URLError where urlError.code == .timedOut {
                print("[StreamCache] Timeout for \(songId), no retry")
                activeFormats.removeValue(forKey: songId)
                activeTasks.removeValue(forKey: songId)
                return
            } catch {
                guard !Task.isCancelled else { return }
                print("[StreamCache] Attempt \(attempt)/\(maxAttempts) error: \(error.localizedDescription)")
                if attempt < maxAttempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        activeFormats.removeValue(forKey: songId)
        activeTasks.removeValue(forKey: songId)
        print("[StreamCache] All attempts failed for \(songId)")
    }
}
