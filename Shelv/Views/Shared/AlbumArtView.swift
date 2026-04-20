import SwiftUI

struct AlbumArtView: View {
    let coverArtId: String?
    let size: Int
    let cornerRadius: CGFloat
    let isCircle: Bool

    init(coverArtId: String?, size: Int = 300, cornerRadius: CGFloat = 12, isCircle: Bool = false) {
        self.coverArtId = coverArtId
        self.size = size
        self.cornerRadius = cornerRadius
        self.isCircle = isCircle
    }

    @State private var uiImage: UIImage? = nil
    @State private var loading = true
    @State private var didCheck = false

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
                content.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
        .onAppear {
            guard !didCheck else { return }
            didCheck = true
            if let id = coverArtId {
                let key = "\(id)_\(size)"
                if let cached = ImageCacheService.shared.cachedImage(key: key) {
                    uiImage = cached
                    loading = false
                }
            } else {
                loading = false
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

        // Gecachtes Bild sofort setzen — kein Flash, kein Spinner
        if let cached = ImageCacheService.shared.cachedImage(key: key) {
            uiImage = cached
            loading = false
            return
        }

        // Kein Cache → altes Cover wegräumen, neu laden
        uiImage = nil
        loading = true

        // Bis zu 3 Versuche bei fehlgeschlagenem Laden
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(Int64(500 * attempt)))
            }
            guard !Task.isCancelled else { return }

            let image = await ImageCacheService.shared.image(url: url, key: key)
            guard !Task.isCancelled else { return }

            if let image {
                uiImage = image
                loading = false
                return
            }
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
