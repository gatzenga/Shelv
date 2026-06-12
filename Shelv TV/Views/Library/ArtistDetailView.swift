import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    private let player = AudioPlayerService.shared

    @State private var albums: [Album] = []
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 60)]

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 24) {
                    CoverArtView(url: artist.coverURL(600), size: 280, isCircle: true)
                    Text(artist.name).font(.largeTitle).bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .padding(.bottom, 20)

                LazyVGrid(columns: columns, spacing: 60) {
                    ForEach(albums) { album in
                        AlbumCard(album: album, size: 280)
                    }
                }
            }
            // Padding im Scrollbereich, damit der .card-Lift nicht an den Kanten clippt.
            .padding(.horizontal, 50)
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .task {
            if let detail = await LibraryStore.shared.artistDetail(artist) {
                albums = detail.album ?? []
            }
            isLoading = false
        }
    }
}
