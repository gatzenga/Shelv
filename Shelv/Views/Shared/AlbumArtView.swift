import SwiftUI

struct AlbumArtView: View {
    let coverArtId: String?
    let size: Int
    let cornerRadius: CGFloat
    let isCircle: Bool

    @State private var uiImage: UIImage?
    @State private var loading: Bool

    init(coverArtId: String?, size: Int = 300, cornerRadius: CGFloat = 12, isCircle: Bool = false) {
        self.coverArtId = coverArtId
        self.size = size
        self.cornerRadius = cornerRadius
        self.isCircle = isCircle

        // Synchroner Cache-Check beim Init: liefert das Bild sofort beim ersten Render,
        // verhindert den ProgressView-Flash + die Doppel-State-Mutation während Scroll.
        if let id = coverArtId,
           let cached = ImageCacheService.shared.cachedImage(key: "\(id)_\(size)") {
            self._uiImage = State(initialValue: cached)
            self._loading = State(initialValue: false)
        } else {
            self._uiImage = State(initialValue: nil)
            self._loading = State(initialValue: coverArtId != nil)
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
        .task(id: coverArtId) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard let id = coverArtId,
              let url = SubsonicAPIService.shared.coverArtURL(for: id, size: size)
        else { uiImage = nil; loading = false; return }

        let key = "\(id)_\(size)"

        if let cached = ImageCacheService.shared.cachedImage(key: key) {
            uiImage = cached; loading = false; return
        }

        // Stale-while-revalidate: altes Bild bleibt sichtbar während neues lädt.
        // Spinner nur wenn noch kein Bild vorhanden ist.
        if uiImage == nil { loading = true }

        if let localPath = LocalArtworkIndex.shared.localPath(for: id) {
            let loaded: UIImage? = await Task.detached(priority: .medium) {
                UIImage(contentsOfFile: localPath)
            }.value
            if let img = loaded {
                ImageCacheService.shared.cache(img, key: key)
                uiImage = img; loading = false; return
            }
        }

        if UserDefaults.standard.bool(forKey: "offlineModeEnabled") {
            if let img = await ImageCacheService.shared.diskOnlyImage(key: key) {
                uiImage = img
            }
            loading = false
            return
        }

        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(Int64(500 * attempt)))
            }
            guard !Task.isCancelled else { return }
            let image = await ImageCacheService.shared.image(url: url, key: key)
            guard !Task.isCancelled else { return }
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

}
