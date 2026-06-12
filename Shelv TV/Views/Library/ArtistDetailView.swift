import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    private let player = AudioPlayerService.shared

    @State private var albums: [Album] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(spacing: 24) {
                    CoverArtView(url: artist.coverURL(600), size: 280, isCircle: true)
                    Text(artist.name).font(.largeTitle).bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .padding(.bottom, 20)

                LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                    ForEach(albums) { album in
                        AlbumCard(album: album)
                    }
                }
            }
            .padding(.horizontal, 50)
            .padding(.top, 30)
            .padding(.bottom, 50)
        }
        .task {
            if let detail = await LibraryStore.shared.artistDetail(artist) {
                albums = detail.album ?? []
            }
            isLoading = false
        }
    }
}
