import SwiftUI

struct AlbumArtView: View {
    let coverArtId: String?
    let size: Int
    let cornerRadius: CGFloat
    let isCircle: Bool
    let reloadToken: UUID?

    @State private var uiImage: UIImage?
    @State private var loadedIdentifier: String?
    @State private var loading: Bool
    @State private var loadRequest = ArtworkLoadRequestTracker()

    init(
        coverArtId: String?,
        size: Int = 300,
        cornerRadius: CGFloat = 12,
        isCircle: Bool = false,
        reloadToken: UUID? = nil
    ) {
        self.coverArtId = coverArtId
        self.size = size
        self.cornerRadius = cornerRadius
        self.isCircle = isCircle
        self.reloadToken = reloadToken

        // Synchroner Memory-Check beim Init: exakte Größe bevorzugt, andere gecachte
        // Größen als sofortiger Stale-Fallback gegen ProgressView-Flashes.
        if let id = coverArtId {
            let cached = ImageCacheService.shared.cachedImage(
                key: "\(id)_\(size)",
                fallbackSizes: ImageCacheService.coverFallbackSizes(preferred: size)
            )
            self._uiImage = State(initialValue: cached)
            self._loadedIdentifier = State(initialValue: cached == nil ? nil : "\(id)_\(size)")
            self._loading = State(initialValue: cached == nil)
        } else {
            self._uiImage = State(initialValue: nil)
            self._loadedIdentifier = State(initialValue: nil)
            self._loading = State(initialValue: false)
        }
    }

    var body: some View {
        let content = Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let uiImage, loadedIdentifier == loadIdentifier {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else if loading {
                    Color.gray.opacity(0.2)
                        .overlay(ProgressView().tint(.secondary))
                } else {
                    placeholder
                }
            }
        return Group {
            if isCircle {
                content.clipShape(Circle())
            } else {
                content.cornerRadius(cornerRadius)
            }
        }
        .task(id: taskIdentifier) {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .artworkIndexReady)) { _ in
            guard uiImage == nil || loadedIdentifier != loadIdentifier else { return }
            Task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard let id = coverArtId else {
            loadRequest.reset()
            uiImage = nil
            loadedIdentifier = nil
            loading = false
            return
        }

        let expectedLoadIdentifier = loadIdentifier
        loadRequest.begin(expectedLoadIdentifier)
        if loadedIdentifier != expectedLoadIdentifier {
            uiImage = nil
            loadedIdentifier = nil
        }
        loading = uiImage == nil
        let key = "\(id)_\(size)"
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: size)

        if let cached = ImageCacheService.shared.cachedImage(key: key) {
            apply(cached, for: expectedLoadIdentifier)
            return
        }
        if let cached = ImageCacheService.shared.cachedImage(key: key, fallbackSizes: fallbackSizes) {
            apply(cached, for: expectedLoadIdentifier)
        }

        #if DEBUG
        // Demo-Cover liegen als Asset-Imagesets im Bundle (Präfix `demo_`), nicht im Netz.
        if id.hasPrefix("demo_") {
            if let cached = ImageCacheService.shared.cachedImage(key: key, fallbackSizes: fallbackSizes) {
                apply(cached, for: expectedLoadIdentifier)
            }
            else if let img = UIImage(named: id) {
                ImageCacheService.shared.cache(img, key: key)
                apply(img, for: expectedLoadIdentifier)
            }
            loading = false
            return
        }
        #endif

        guard let url = SubsonicAPIService.shared.coverArtURL(for: id, size: size)
        else {
            uiImage = nil
            loadedIdentifier = nil
            loading = false
            return
        }

        // Ein Bild einer anderen Cover-ID bleibt nie sichtbar.
        if uiImage == nil { loading = true }

        if let localPath = LocalArtworkIndex.shared.localPath(for: id) {
            let loaded: UIImage? = await Task.detached(priority: .medium) {
                UIImage(contentsOfFile: localPath)
            }.value
            guard loadRequest.accepts(expectedLoadIdentifier) else { return }
            if let img = loaded {
                ImageCacheService.shared.cache(img, key: key)
                apply(img, for: expectedLoadIdentifier)
                return
            }
        }

        if let cached = await ImageCacheService.shared.diskOnlyImage(key: key, fallbackSizes: fallbackSizes) {
            guard loadRequest.accepts(expectedLoadIdentifier) else { return }
            apply(cached, for: expectedLoadIdentifier)
        }

        if UserDefaults.standard.bool(forKey: "offlineModeEnabled") {
            loading = false
            return
        }

        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(Int64(500 * attempt)))
            }
            guard !Task.isCancelled else { return }
            let image = await ImageCacheService.shared.image(url: url, key: key)
            guard loadRequest.accepts(expectedLoadIdentifier) else { return }
            if let image {
                apply(image, for: expectedLoadIdentifier)
                return
            }
        }
        loading = false
    }

    private func apply(_ image: UIImage, for identifier: String) {
        guard loadRequest.accepts(identifier) else { return }
        uiImage = image
        loadedIdentifier = identifier
        loading = false
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.15)
            Image(systemName: isCircle ? "person.fill" : "music.note")
                .font(.system(size: CGFloat(size) * 0.2))
                .foregroundStyle(.secondary)
        }
    }

    private var loadIdentifier: String {
        "\(coverArtId ?? "none")_\(size)"
    }

    private var taskIdentifier: String {
        "\(loadIdentifier)|\(reloadToken?.uuidString ?? "static")"
    }

}
