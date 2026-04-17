import UIKit

actor ImageCacheService {
    static let shared = ImageCacheService()

    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private let cacheDir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memory.countLimit = 200
        memory.totalCostLimit = 100 * 1024 * 1024
    }

    /// Synchroner Memory-Cache-Lookup — kein Actor-Hop nötig (NSCache ist thread-safe)
    nonisolated func cachedImage(key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    func image(url: URL, key: String) async -> UIImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }

        if let existing = inflight[key] {
            return await existing.value
        }

        let diskURL = cacheDir.appendingPathComponent(key)

        let task = Task.detached(priority: .medium) { () -> UIImage? in
            if Task.isCancelled { return nil }
            if let data = try? Data(contentsOf: diskURL),
               let img = UIImage(data: data) {
                return img
            }
            if Task.isCancelled { return nil }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return nil }
            if Task.isCancelled { return nil }
            try? data.write(to: diskURL, options: .atomic)
            return img
        }

        inflight[key] = task
        let img = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inflight.removeValue(forKey: key)

        if let img {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: key as NSString, cost: cost)
        }

        return img
    }

    func clearAll() {
        memory.removeAllObjects()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func diskUsageBytes() -> Int {
        FileManager.default.directorySize(at: cacheDir)
    }
}
