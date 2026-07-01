import UIKit

actor ImageCacheService {
    static let shared = ImageCacheService()

    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private let cacheDir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var writesSinceTrim = 0

    private static let diskLimitBytes = 1_073_741_824 // 1 GB
    private static let diskTrimTarget  = 900 * 1024 * 1024 // 900 MB (hysteresis)
    private static let writesPerTrimCheck = 20
    private static let defaultFallbackSizes = [600, 300, 240, 200, 192, 180, 160, 156, 150, 120, 100, 80, 50]

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

    nonisolated func cachedImage(key: String, fallbackSizes: [Int]) -> UIImage? {
        for candidate in Self.candidateKeys(for: key, fallbackSizes: fallbackSizes) {
            if let hit = memory.object(forKey: candidate as NSString) {
                return hit
            }
        }
        return nil
    }

    nonisolated func cache(_ img: UIImage, key: String) {
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key as NSString, cost: cost)
    }

    nonisolated static func coverFallbackSizes(preferred size: Int) -> [Int] {
        var seen = Set<Int>()
        return ([size] + defaultFallbackSizes).filter { seen.insert($0).inserted }
    }

    func diskOnlyImage(key: String, fallbackSizes: [Int] = ImageCacheService.defaultFallbackSizes) async -> UIImage? {
        await diskOnlyImageResult(key: key, fallbackSizes: fallbackSizes)?.image
    }

    func diskOnlyImageResult(
        key: String,
        fallbackSizes: [Int] = ImageCacheService.defaultFallbackSizes
    ) async -> (key: String, image: UIImage)? {
        let candidates = Self.candidateKeys(for: key, fallbackSizes: fallbackSizes)
        for candidate in candidates {
            if let hit = memory.object(forKey: candidate as NSString) {
                return (candidate, hit)
            }
        }
        let dir = cacheDir
        let result = await Task.detached(priority: .medium) { () -> (String, UIImage)? in
            for candidate in candidates {
                let fallbackURL = dir.appendingPathComponent(candidate.pathSafeComponent)
                guard let data = try? Data(contentsOf: fallbackURL),
                      let img = UIImage(data: data) else { continue }
                return (candidate, img)
            }
            return nil
        }.value
        if let (candidate, img) = result {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: candidate as NSString, cost: cost)
            return (candidate, img)
        }
        return nil
    }

    func image(url: URL, key: String) async -> UIImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }

        if let existing = inflight[key] {
            return await existing.value
        }

        let diskURL = cacheDir.appendingPathComponent(key.pathSafeComponent)

        let task = Task.detached(priority: .medium) { () -> UIImage? in
            if Task.isCancelled { return nil }
            if let data = try? Data(contentsOf: diskURL),
               let img = UIImage(data: data) {
                return img
            }
            if Task.isCancelled { return nil }
            guard let (data, img) = await Self.downloadImage(from: url) else { return nil }
            if Task.isCancelled { return nil }
            try? data.write(to: diskURL, options: .atomic)
            return img
        }

        inflight[key] = task
        let img = await task.value
        inflight.removeValue(forKey: key)

        if let img {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: key as NSString, cost: cost)
            writesSinceTrim += 1
            if writesSinceTrim >= Self.writesPerTrimCheck {
                writesSinceTrim = 0
                let dir = cacheDir
                Task.detached(priority: .utility) {
                    Self.trimDiskCache(cacheDir: dir)
                }
            }
        }

        return img
    }

    nonisolated private static func downloadImage(from url: URL) async -> (Data, UIImage)? {
        for attempt in 1...3 {
            if Task.isCancelled { return nil }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 12
            if let (data, response) = try? await URLSession.shared.data(for: request),
               isSuccessfulImageResponse(response),
               let image = UIImage(data: data) {
                return (data, image)
            }
            if attempt < 3 {
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        return nil
    }

    nonisolated private static func isSuccessfulImageResponse(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }

    private nonisolated static func candidateKeys(for key: String, fallbackSizes: [Int]) -> [String] {
        var keys = [key]
        guard let lastUnderscore = key.lastIndex(of: "_") else { return keys }
        let idPrefix = String(key[key.startIndex..<lastUnderscore]) + "_"
        for size in fallbackSizes {
            let fallbackKey = "\(idPrefix)\(size)"
            guard fallbackKey != key, !keys.contains(fallbackKey) else { continue }
            keys.append(fallbackKey)
        }
        return keys
    }

    private nonisolated static func trimDiskCache(cacheDir: URL) {
        let fm = FileManager.default
        guard fm.directorySize(at: cacheDir) > diskLimitBytes else { return }
        guard let items = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let sorted = items.compactMap { url -> (URL, Date, Int)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values?.contentModificationDate,
                  let size = values?.fileSize else { return nil }
            return (url, date, size)
        }.sorted { $0.1 < $1.1 }

        var total = sorted.reduce(0) { $0 + $1.2 }
        for (url, _, size) in sorted {
            if total <= diskTrimTarget { break }
            try? fm.removeItem(at: url)
            total -= size
        }
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
