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
        let image = await ImageCacheService.shared.image(url: url, key: "\(id)_\(size)")
        guard !Task.isCancelled else { return }
        uiImage = image
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
