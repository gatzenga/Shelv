import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    private let player = AudioPlayerService.shared

    @State private var albums: [Album] = []
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 40)]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                CoverArtView(url: artist.coverURL(600), size: 280, isCircle: true)
                Text(artist.name).font(.largeTitle).bold()
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 30)

            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(albums) { album in
                    AlbumCard(album: album, size: 280)
                }
            }
        }
        .padding(50)
        .task {
            if let detail = await LibraryStore.shared.artistDetail(artist) {
                albums = detail.album ?? []
            }
            isLoading = false
        }
    }
}
