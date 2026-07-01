import SwiftUI

struct AlbumArtView: View {
    let coverArtId: String?
    let size: Int
    let cornerRadius: CGFloat
    let isCircle: Bool

    @State private var uiImage: UIImage?
    @State private var loading: Bool
    @State private var activeLoadIdentifier: String?

    init(coverArtId: String?, size: Int = 300, cornerRadius: CGFloat = 12, isCircle: Bool = false) {
        self.coverArtId = coverArtId
        self.size = size
        self.cornerRadius = cornerRadius
        self.isCircle = isCircle

        // Synchroner Memory-Check beim Init: exakte Größe bevorzugt, andere gecachte
        // Größen als sofortiger Stale-Fallback gegen ProgressView-Flashes.
        if let id = coverArtId {
            let cached = ImageCacheService.shared.cachedImage(
                key: "\(id)_\(size)",
                fallbackSizes: ImageCacheService.coverFallbackSizes(preferred: size)
            )
            self._uiImage = State(initialValue: cached)
            self._loading = State(initialValue: cached == nil)
        } else {
            self._uiImage = State(initialValue: nil)
            self._loading = State(initialValue: false)
        }
    }

    var body: some View {
        let content = Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let uiImage {
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
        .task(id: loadIdentifier) {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .artworkIndexReady)) { _ in
            guard uiImage == nil else { return }
            Task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard let id = coverArtId else {
            activeLoadIdentifier = nil
            uiImage = nil
            loading = false
            return
        }

        let expectedLoadIdentifier = loadIdentifier
        activeLoadIdentifier = expectedLoadIdentifier
        let key = "\(id)_\(size)"
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: size)

        if let cached = ImageCacheService.shared.cachedImage(key: key) {
            uiImage = cached; loading = false; return
        }
        if let cached = ImageCacheService.shared.cachedImage(key: key, fallbackSizes: fallbackSizes) {
            uiImage = cached
            loading = false
        }

        #if DEBUG
        // Demo-Cover liegen als Asset-Imagesets im Bundle (Präfix `demo_`), nicht im Netz.
        if id.hasPrefix("demo_") {
            if let cached = ImageCacheService.shared.cachedImage(key: key, fallbackSizes: fallbackSizes) { uiImage = cached }
            else if let img = UIImage(named: id) {
                ImageCacheService.shared.cache(img, key: key)
                uiImage = img
            }
            loading = false
            return
        }
        #endif

        guard let url = SubsonicAPIService.shared.coverArtURL(for: id, size: size)
        else { uiImage = nil; loading = false; return }

        // Stale-while-revalidate: altes Bild bleibt sichtbar während neues lädt.
        // Spinner nur wenn noch kein Bild vorhanden ist.
        if uiImage == nil { loading = true }

        if let localPath = LocalArtworkIndex.shared.localPath(for: id) {
            let loaded: UIImage? = await Task.detached(priority: .medium) {
                UIImage(contentsOfFile: localPath)
            }.value
            guard !Task.isCancelled, activeLoadIdentifier == expectedLoadIdentifier else { return }
            if let img = loaded {
                ImageCacheService.shared.cache(img, key: key)
                uiImage = img; loading = false; return
            }
        }

        if let cached = await ImageCacheService.shared.diskOnlyImage(key: key, fallbackSizes: fallbackSizes) {
            guard !Task.isCancelled, activeLoadIdentifier == expectedLoadIdentifier else { return }
            uiImage = cached
            loading = false
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
            guard !Task.isCancelled, activeLoadIdentifier == expectedLoadIdentifier else { return }
            if let image { uiImage = image; loading = false; return }
        }
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

}
