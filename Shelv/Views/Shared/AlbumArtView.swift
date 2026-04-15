import SwiftUI

struct AlbumArtView: View {
    let coverArtId: String?
    let size: Int
    let cornerRadius: CGFloat

    init(coverArtId: String?, size: Int = 300, cornerRadius: CGFloat = 12) {
        self.coverArtId = coverArtId
        self.size = size
        self.cornerRadius = cornerRadius
    }

    @State private var uiImage: UIImage? = nil
    @State private var loading = true

    var body: some View {
        Group {
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: coverArtId) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        loading = true
        uiImage = nil
        guard let id = coverArtId,
              let url = SubsonicAPIService.shared.coverArtURL(for: id, size: size)
        else { loading = false; return }

        let key = "\(id)_\(size)"

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
            Image(systemName: "music.note")
                .font(.system(size: CGFloat(size) * 0.2))
                .foregroundStyle(.secondary)
        }
    }
}
