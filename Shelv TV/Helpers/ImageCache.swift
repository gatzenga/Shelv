import SwiftUI
import UIKit

// MARK: - Cover Art View

/// Cover-Anzeige für tvOS. Stale-while-revalidate, Demo-Asset-Auflösung für `demo_`-IDs.
struct CoverArtView: View {
    let url: URL?
    var size: CGFloat = 240
    var cornerRadius: CGFloat = 10
    var isCircle: Bool = false
    var reloadToken: UUID?
    var showsPlaceholder: Bool = true

    @State private var image: UIImage?
    @State private var loadedImageKey: String?
    @State private var loadRequest = ArtworkLoadRequestTracker()
    @State private var connectivityReloadToken = UUID()

    init(
        url: URL?,
        size: CGFloat = 240,
        cornerRadius: CGFloat = 10,
        isCircle: Bool = false,
        reloadToken: UUID? = nil,
        showsPlaceholder: Bool = true
    ) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        self.isCircle = isCircle
        self.reloadToken = reloadToken
        self.showsPlaceholder = showsPlaceholder
        if let url, let cached = ImageCacheService.shared.cachedImage(url: url) {
            self._image = State(initialValue: cached)
            self._loadedImageKey = State(initialValue: ImageCacheService.stableCacheKey(for: url))
        } else {
            self._image = State(initialValue: nil)
            self._loadedImageKey = State(initialValue: nil)
        }
    }

    var body: some View {
        let content = Group {
            if let img = image, loadedImageKey == stableKey {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                if showsPlaceholder {
                    ZStack {
                    Color.gray.opacity(0.25)
                    Image(systemName: isCircle ? "person.fill" : "music.note")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)

        return Group {
            if isCircle {
                content.clipShape(Circle())
            } else {
                content.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
        .onAppear { triggerLoad() }
        .task(id: taskIdentifier) {
            await loadImage(requestIdentifier: taskIdentifier)
        }
        .onReceive(NotificationCenter.default.publisher(for: .networkStatusChanged)) { _ in
            guard ArtworkConnectivityReloadPolicy.shouldReload(
                hasNetwork: NetworkStatus.shared.hasNetwork
            ) else { return }
            connectivityReloadToken = UUID()
        }
    }

    private var stableKey: String {
        guard let url else { return "" }
        return ImageCacheService.stableCacheKey(for: url)
    }

    private func triggerLoad() {
        guard url != nil, loadedImageKey != stableKey else { return }
        let requestIdentifier = taskIdentifier
        Task { await loadImage(requestIdentifier: requestIdentifier) }
    }

    private func loadImage(requestIdentifier: String) async {
        guard let url else {
            loadRequest.reset()
            image = nil
            loadedImageKey = nil
            return
        }
        let key = stableKey
        guard let attempt = loadRequest.beginIfIdle(requestIdentifier) else { return }
        defer { loadRequest.finish(requestIdentifier, attempt: attempt) }

        if let hit = ImageCacheService.shared.cachedImage(url: url) {
            apply(hit, for: key, requestIdentifier: requestIdentifier, attempt: attempt)
            return
        }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let artId = comps?.queryItems?.first(where: { $0.name == "id" })?.value

        #if DEBUG
        if let artId, artId.hasPrefix("demo_") {
            if let img = UIImage(named: artId) {
                ImageCacheService.shared.cache(img, url: url)
                apply(img, for: key, requestIdentifier: requestIdentifier, attempt: attempt)
            }
            return
        }
        #endif

        if let img = await ImageCacheService.shared.diskOnlyImage(url: url) {
            guard isCurrentLoad(requestIdentifier, attempt: attempt) else { return }
            apply(img, for: key, requestIdentifier: requestIdentifier, attempt: attempt)
        }

        if let img = await ImageCacheService.shared.image(url: url) {
            guard isCurrentLoad(requestIdentifier, attempt: attempt) else { return }
            apply(img, for: key, requestIdentifier: requestIdentifier, attempt: attempt)
        }
    }

    private func isCurrentLoad(_ requestIdentifier: String, attempt: UUID) -> Bool {
        loadRequest.accepts(requestIdentifier, attempt: attempt)
    }

    private func apply(
        _ loadedImage: UIImage,
        for key: String,
        requestIdentifier: String,
        attempt: UUID
    ) {
        guard isCurrentLoad(requestIdentifier, attempt: attempt) else { return }
        image = loadedImage
        loadedImageKey = key
    }

    private var taskIdentifier: String {
        "\(stableKey)|\(reloadToken?.uuidString ?? "static")|\(connectivityReloadToken.uuidString)"
    }
}

// MARK: - Image Cache Service

actor ImageCacheService {
    static let shared = ImageCacheService()

    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private let cacheDir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var writesSinceTrim = 0

    private static let diskLimitBytes  = 1_073_741_824
    private static let diskTrimTarget  = 900 * 1024 * 1024
    private static let writesPerTrimCheck = 20

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    private init() {
        cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memory.countLimit = 400
        memory.totalCostLimit = 150 * 1024 * 1024
    }

    nonisolated func cachedImage(url: URL) -> UIImage? {
        memory.object(forKey: Self.stableCacheKey(for: url) as NSString)
    }

    nonisolated func cachedImage(url: URL, fallbackSizes: [Int]) -> (image: UIImage, key: String)? {
        let key = Self.stableCacheKey(for: url)
        if let hit = memory.object(forKey: key as NSString) {
            return (hit, key)
        }
        for fallbackKey in Self.fallbackCacheKeys(for: url, key: key, sizes: fallbackSizes) {
            guard let hit = memory.object(forKey: fallbackKey as NSString) else { continue }
            return (hit, fallbackKey)
        }
        return nil
    }

    nonisolated func cache(_ img: UIImage, url: URL) {
        let key = Self.stableCacheKey(for: url) as NSString
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key, cost: cost)
    }

    func diskOnlyImage(url: URL) async -> UIImage? {
        await diskOnlyImageResult(url: url)?.image
    }

    func diskOnlyImageResult(url: URL, fallbackSizes: [Int]? = nil) async -> (image: UIImage, key: String)? {
        let key = Self.stableCacheKey(for: url)
        let nsKey = key as NSString
        if let hit = memory.object(forKey: nsKey) { return (hit, key) }

        let diskURL = cacheDir.appendingPathComponent(key)
        let dir = cacheDir
        let sizes = fallbackSizes ?? Self.coverFallbackSizes(preferred: Self.preferredSize(for: url))
        let result = await Task.detached(priority: .medium) { () -> (UIImage, String)? in
            if let data = try? Data(contentsOf: diskURL),
               let img = UIImage(data: data) {
                return (img, key)
            }
            for fallbackKey in Self.fallbackCacheKeys(for: url, key: key, sizes: sizes) {
                let fallbackURL = dir.appendingPathComponent(fallbackKey)
                guard let data = try? Data(contentsOf: fallbackURL),
                      let img = UIImage(data: data) else { continue }
                return (img, fallbackKey)
            }
            return nil
        }.value

        if let (img, resolvedKey) = result {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: resolvedKey as NSString, cost: cost)
        }
        return result
    }

    func image(url: URL) async -> UIImage? {
        let key = Self.stableCacheKey(for: url)
        let nsKey = key as NSString

        if let hit = memory.object(forKey: nsKey) { return hit }
        if let existing = inflight[key] { return await existing.value }

        let diskURL = cacheDir.appendingPathComponent(key)
        let task = Task.detached(priority: .userInitiated) { [diskURL] () -> UIImage? in
            if let data = try? Data(contentsOf: diskURL), let img = UIImage(data: data) {
                return img
            }
            return await Self.fetchWithRetry(url: url, diskURL: diskURL)
        }

        inflight[key] = task
        let img = await task.value
        inflight.removeValue(forKey: key)

        if let img {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: nsKey, cost: cost)
            writesSinceTrim += 1
            if writesSinceTrim >= Self.writesPerTrimCheck {
                writesSinceTrim = 0
                let dir = cacheDir
                Task.detached(priority: .utility) { Self.trimDiskCache(cacheDir: dir) }
            }
        }
        return img
    }

    private nonisolated static func trimDiskCache(cacheDir: URL) {
        let fm = FileManager.default
        guard fm.directorySize(at: cacheDir) > diskLimitBytes else { return }
        guard let items = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let sorted = items.compactMap { url -> (URL, Date, Int)? in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = v?.contentModificationDate, let size = v?.fileSize else { return nil }
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

    nonisolated static func coverFallbackSizes(preferred: Int) -> [Int] {
        var seen = Set<Int>()
        return [preferred, 700, 600, 500, 400, 380, 320, 300, 240, 200, 180, 160, 156, 150, 120, 100, 80, 50]
            .filter { $0 > 0 && seen.insert($0).inserted }
    }

    private nonisolated static func preferredSize(for url: URL) -> Int {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let size = components?.queryItems?.first(where: { $0.name == "size" })?.value
        return Int(size ?? "") ?? 600
    }

    private nonisolated static func fallbackCacheKeys(for url: URL, key: String, sizes: [Int]) -> [String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let coverID = components?.queryItems?.first(where: { $0.name == "id" })?.value,
              !coverID.isEmpty,
              let lastUnderscore = key.lastIndex(of: "_")
        else { return [] }

        let idPrefix = String(key[key.startIndex..<lastUnderscore]) + "_"
        return sizes.map { "\(idPrefix)\($0)" }.filter { $0 != key }
    }

    /// Stabiler Cache-Schlüssel `host_id_size` — ignoriert rotierende Auth-Token.
    static func stableCacheKey(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let radioRevision = components?.queryItems?.first(where: { $0.name == RadioNowPlayingMetadata.artworkRevisionQueryItemName })?.value,
           !radioRevision.isEmpty {
            let host = url.host ?? "local"
            let path = url.path.isEmpty ? "art" : url.path
            let safePath = path.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            let safeRevision = radioRevision.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            return "\(host)_radio_\(safePath)_\(safeRevision)"
        }
        let id   = components?.queryItems?.first(where: { $0.name == "id"   })?.value ?? ""
        let size = components?.queryItems?.first(where: { $0.name == "size" })?.value ?? "0"
        let host = url.host ?? "local"
        let safeId = id.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return "\(host)_\(safeId)_\(size)"
    }

    private static func fetchWithRetry(url: URL, diskURL: URL) async -> UIImage? {
        let isRadioArtwork = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == RadioNowPlayingMetadata.artworkRevisionQueryItemName }) == true
        let maximumAttempts = isRadioArtwork ? 1 : 3
        for attempt in 0..<maximumAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(500_000_000) * UInt64(attempt))
            }
            var request = URLRequest(url: url)
            if isRadioArtwork { request.timeoutInterval = 8 }
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data) else { continue }
            try? data.write(to: diskURL, options: .atomic)
            return img
        }
        return nil
    }
}
