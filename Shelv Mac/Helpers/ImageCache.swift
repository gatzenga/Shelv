import SwiftUI
import AppKit

// MARK: - Cover Art View

struct CoverArtView: View {
    let url: URL?
    var size: CGFloat = 180
    var cornerRadius: CGFloat = 8
    var isCircle: Bool = false

    @State private var image: NSImage?

    init(url: URL?, size: CGFloat = 180, cornerRadius: CGFloat = 8, isCircle: Bool = false) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        self.isCircle = isCircle
        if let url, let cached = ImageCacheService.shared.cachedImage(url: url) {
            self._image = State(initialValue: cached)
        } else {
            self._image = State(initialValue: nil)
        }
    }

    var body: some View {
        let content = Group {
            if let img = image {
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
        // task(id: stableKey): lädt neu wenn sich das Cover ändert,
        // aber NICHT bei jedem Auth-Token-Wechsel in der URL.
        .task(id: stableKey) { await loadImage() }
    }

    // Stabiler Schlüssel aus Cover-ID + Grösse + Host — ohne rotierende Auth-Tokens.
    private var stableKey: String {
        guard let url else { return "" }
        return ImageCacheService.stableCacheKey(for: url)
    }

    private func triggerLoad() {
        guard image == nil, url != nil else { return }
        Task { await loadImage() }
    }

    private func loadImage() async {
        guard let url else { image = nil; return }

        if let hit = ImageCacheService.shared.cachedImage(url: url) {
            image = hit; return
        }

        // Stale-while-revalidate: altes Bild bleibt sichtbar während neues lädt.
        // image nicht auf nil setzen — neues Bild ersetzt erst wenn fertig.

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let artId = comps?.queryItems?.first(where: { $0.name == "id" })?.value

        #if DEBUG
        if let artId, artId.hasPrefix("demo_") {
            if let img = NSImage(named: artId) {
                ImageCacheService.shared.cache(img, url: url)
                image = img
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
                image = img
                return
            }
        }

        if UserDefaults.standard.bool(forKey: "offlineModeEnabled") {
            if let img = await ImageCacheService.shared.diskOnlyImage(url: url) {
                image = img
            }
        } else {
            if let img = await ImageCacheService.shared.image(url: url) {
                image = img
            }
        }
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

    nonisolated func cache(_ img: NSImage, url: URL) {
        let key = Self.stableCacheKey(for: url) as NSString
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key, cost: cost)
    }

    func diskOnlyImage(url: URL) async -> NSImage? {
        let key = Self.stableCacheKey(for: url)
        let nsKey = key as NSString
        if let hit = memory.object(forKey: nsKey) { return hit }
        let diskURL = cacheDir.appendingPathComponent(key)
        let dir = cacheDir
        let img = await Task.detached(priority: .medium) { () -> NSImage? in
            if let data = try? Data(contentsOf: diskURL),
               let img = NSImage(data: data) {
                return img
            }
            // Fallback: gleiche Cover-ID, andere gecachte Grösse
            guard let lastUnderscore = key.lastIndex(of: "_") else { return nil }
            let idPrefix = String(key[key.startIndex..<lastUnderscore]) + "_"
            let fallbackSizes = [200, 320, 160, 120, 240, 80, 100, 50]
            for size in fallbackSizes {
                let fallbackKey = "\(idPrefix)\(size)"
                guard fallbackKey != key else { continue }
                let fallbackURL = dir.appendingPathComponent(fallbackKey)
                guard let data = try? Data(contentsOf: fallbackURL),
                      let img = NSImage(data: data) else { continue }
                return img
            }
            return nil
        }.value
        if let img {
            let cost = Int(img.size.width * img.size.height * 4)
            memory.setObject(img, forKey: nsKey, cost: cost)
        }
        return img
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

    // MARK: - Stabiler Cache-Schlüssel

    /// Extrahiert `host_id_size` aus der URL — ignoriert rotierende Auth-Token (t, s).
    /// Stabil über App-Neustarts hinweg (kein hashValue).
    static func stableCacheKey(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
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
