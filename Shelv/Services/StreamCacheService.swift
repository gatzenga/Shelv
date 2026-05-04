import Foundation

actor StreamCacheService {
    static let shared = StreamCacheService()
    private init() {}

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var cachedURLs: [String: URL] = [:]
    private var cachedFormats: [String: ActualStreamFormat] = [:]

    private static func tempURL(for songId: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shelv_stream_\(songId)")
    }

    func localURL(for songId: String) -> URL? {
        cachedURLs[songId]
    }

    func cachedFormat(for songId: String) -> ActualStreamFormat? {
        cachedFormats[songId]
    }

    func prefetch(songId: String, url: URL, codec: String, bitrate: Int) {
        guard activeTasks[songId] == nil, cachedURLs[songId] == nil else { return }
        let format = ActualStreamFormat(codecLabel: codec.uppercased(), bitrateKbps: bitrate)
        cachedFormats[songId] = format
        activeTasks[songId] = Task {
            await downloadWithRetry(songId: songId, url: url, maxAttempts: 3)
        }
    }

    func cancel(songId: String) {
        activeTasks[songId]?.cancel()
        activeTasks.removeValue(forKey: songId)
        cachedURLs.removeValue(forKey: songId)
        cachedFormats.removeValue(forKey: songId)
        try? FileManager.default.removeItem(at: Self.tempURL(for: songId))
    }

    func cancelAll() {
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        cachedURLs.removeAll()
        cachedFormats.removeAll()
    }

    func cleanupOldFiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("shelv_stream_") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func downloadWithRetry(songId: String, url: URL, maxAttempts: Int) async {
        let dest = Self.tempURL(for: songId)
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
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                cachedURLs[songId] = dest
                activeTasks.removeValue(forKey: songId)
                print("[StreamCache] Cached \(songId)")
                return
            } catch {
                guard !Task.isCancelled else { return }
                print("[StreamCache] Attempt \(attempt)/\(maxAttempts) error: \(error.localizedDescription)")
                if attempt < maxAttempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        activeTasks.removeValue(forKey: songId)
        print("[StreamCache] All attempts failed for \(songId)")
    }
}
