import SwiftUI
import AppKit

// MARK: - Cover Art View

struct CoverArtView: View {
    let url: URL?
    var size: CGFloat = 180
    var cornerRadius: CGFloat = 8
    var isCircle: Bool = false
    var reloadToken: UUID?

    @State private var image: NSImage?
    @State private var loadedImageKey: String?
    @State private var loadRequest = ArtworkLoadRequestTracker()

    init(
        url: URL?,
        size: CGFloat = 180,
        cornerRadius: CGFloat = 8,
        isCircle: Bool = false,
        reloadToken: UUID? = nil
    ) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        self.isCircle = isCircle
        self.reloadToken = reloadToken
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
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor).opacity(0.6)
                    Image(systemName: isCircle ? "person.fill" : "music.note")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.secondary)
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
        // onAppear: zuverlässiger Fallback für LazyVGrid auf macOS,
        // das .task manchmal erst bei Hover triggert.
        .onAppear { triggerLoad() }
        // Lädt bei einem neuen Cover oder einem gezielten Radio-Refresh neu,
        // aber nicht bei jedem Auth-Token-Wechsel in der URL.
        .task(id: loadIdentifier) { await loadImage() }
    }

    // Stabiler Schlüssel aus Cover-ID + Grösse + Host — ohne rotierende Auth-Tokens.
    private var stableKey: String {
        guard let url else { return "" }
        return ImageCacheService.stableCacheKey(for: url)
    }

    private var loadIdentifier: String {
        "\(stableKey)|\(reloadToken?.uuidString ?? "static")"
    }

    private func triggerLoad() {
        guard image == nil, url != nil else { return }
        Task { await loadImage() }
    }

    private func loadImage() async {
        guard let url else {
            loadRequest.reset()
            image = nil
            loadedImageKey = nil
            return
        }
        let key = stableKey
        guard loadRequest.activeIdentifier != key else { return }
        loadRequest.begin(key)
        defer { loadRequest.finish(key) }

        if let hit = ImageCacheService.shared.cachedImage(url: url) {
            apply(hit, for: key)
            return
        }

        // Stale-while-revalidate: altes Bild bleibt sichtbar während neues lädt.
        // image nicht auf nil setzen — neues Bild ersetzt erst wenn fertig.

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let artId = comps?.queryItems?.first(where: { $0.name == "id" })?.value

        #if DEBUG
        if let artId, artId.hasPrefix("demo_") {
            if let img = NSImage(named: artId) {
                ImageCacheService.shared.cache(img, url: url)
                apply(img, for: key)
            }
            return
        }
        #endif

        if let artId,
           let localPath = LocalArtworkIndex.shared.localPath(for: artId) {
            let loaded: NSImage? = await Task.detached(priority: .medium) {
                NSImage(contentsOfFile: localPath)
            }.value
            if let img = loaded {
                ImageCacheService.shared.cache(img, url: url)
                guard isCurrentLoad(key) else { return }
                apply(img, for: key)
                return
            }
        }

        if let img = await ImageCacheService.shared.diskOnlyImage(url: url) {
            guard isCurrentLoad(key) else { return }
            apply(img, for: key)
            if UserDefaults.standard.bool(forKey: "offlineModeEnabled") { return }
        }

        if let img = await ImageCacheService.shared.image(url: url) {
            guard isCurrentLoad(key) else { return }
            apply(img, for: key)
        }
    }

    private func isCurrentLoad(_ key: String) -> Bool {
        loadRequest.accepts(key)
    }

    private func apply(_ loadedImage: NSImage, for key: String) {
        guard isCurrentLoad(key) else { return }
        image = loadedImage
        loadedImageKey = key
    }
}

// MARK: - Image Cache Service

actor ImageCacheService {
    static let shared = ImageCacheService()

    nonisolated(unsafe) private let memory = NSCache<NSString, NSImage>()
    private let cacheDir: URL
    private var inflight: [String: Task<NSImage?, Never>] = [:]
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

    nonisolated func cachedImage(url: URL) -> NSImage? {
        memory.object(forKey: Self.stableCacheKey(for: url) as NSString)
    }

    nonisolated func cachedImage(url: URL, fallbackSizes: [Int]) -> (image: NSImage, key: String)? {
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

    nonisolated func cache(_ img: NSImage, url: URL) {
        let key = Self.stableCacheKey(for: url) as NSString
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key, cost: cost)
    }

    func diskOnlyImage(url: URL) async -> NSImage? {
        await diskOnlyImageResult(url: url)?.image
    }

    func diskOnlyImageResult(url: URL, fallbackSizes: [Int]? = nil) async -> (image: NSImage, key: String)? {
        let key = Self.stableCacheKey(for: url)
        let nsKey = key as NSString
        if let hit = memory.object(forKey: nsKey) { return (hit, key) }
        let diskURL = cacheDir.appendingPathComponent(key)
        let dir = cacheDir
        let sizes = fallbackSizes ?? Self.coverFallbackSizes(preferred: Self.preferredSize(for: url))
        let result = await Task.detached(priority: .medium) { () -> (NSImage, String)? in
            if let data = try? Data(contentsOf: diskURL),
               let img = NSImage(data: data) {
                return (img, key)
            }
            for fallbackKey in Self.fallbackCacheKeys(for: url, key: key, sizes: sizes) {
                let fallbackURL = dir.appendingPathComponent(fallbackKey)
                guard let data = try? Data(contentsOf: fallbackURL),
                      let img = NSImage(data: data) else { continue }
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

    func image(url: URL) async -> NSImage? {
        let key = Self.stableCacheKey(for: url)
        let nsKey = key as NSString

        // 1. Speicher-Treffer — sofortige Rückgabe
        if let hit = memory.object(forKey: nsKey) { return hit }

        // 2. Laufende Anfrage deuplizieren
        if let existing = inflight[key] { return await existing.value }

        // 3. Neuen Download starten (detached → wird nicht abgebrochen wenn View verschwindet)
        let diskURL = cacheDir.appendingPathComponent(key)
        let task = Task.detached(priority: .userInitiated) { [diskURL] () -> NSImage? in
            // Disk-Cache prüfen
            if let data = try? Data(contentsOf: diskURL),
               let img = NSImage(data: data) {
                return img
            }
            // Netzwerk mit 3 Versuchen
            return await Self.fetchWithRetry(url: url, diskURL: diskURL)
        }

        inflight[key] = task
        // Kein withTaskCancellationHandler — der Download läuft durch,
        // auch wenn der aufrufende View-Task abgebrochen wird.
        let img = await task.value
        inflight.removeValue(forKey: key)

        if let img {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: nsKey, cost: cost)
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

    // MARK: - Stabiler Cache-Schlüssel

    /// Extrahiert `host_id_size` aus der URL — ignoriert rotierende Auth-Token (t, s).
    /// Stabil über App-Neustarts hinweg (kein hashValue).
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
        // Nur alphanumerische Zeichen → sicherer Dateiname
        let safeId = id.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return "\(host)_\(safeId)_\(size)"
    }

    // MARK: - Netzwerk mit Retry

    private static func fetchWithRetry(url: URL, diskURL: URL) async -> NSImage? {
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(500_000_000) * UInt64(attempt))
            }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data) else { continue }
            try? data.write(to: diskURL, options: .atomic)
            return img
        }
        return nil
    }
}
