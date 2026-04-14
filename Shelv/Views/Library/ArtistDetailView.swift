import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject var player: AudioPlayerService
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var detail: ArtistDetail?
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    AlbumArtView(coverArtId: artist.coverArt, size: 300, cornerRadius: 50)
                        .frame(width: 100, height: 100)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name)
                            .font(.title2).bold()
                        if let count = artist.albumCount {
                            Text("\(count) \(tr("Albums", "Alben"))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let albums = detail?.album, !albums.isEmpty {
                    Text(tr("Albums", "Alben"))
                        .font(.title3).bold()
                        .padding(.horizontal)

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCardView(album: album, showArtist: false, showYear: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, player.currentSong != nil ? 90 : 16)
                }
            }
            .padding(.top, 16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        isLoading = true
        do {
            detail = try await SubsonicAPIService.shared.getArtist(id: artist.id)
        } catch {}
        isLoading = false
    }
}
