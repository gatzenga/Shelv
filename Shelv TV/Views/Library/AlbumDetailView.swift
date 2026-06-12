import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    private let player = AudioPlayerService.shared

    @State private var songs: [Song] = []
    @State private var isLoading = true

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 40) {
                    CoverArtView(url: album.coverURL(600), size: 360, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(album.name).font(.title).bold().lineLimit(2)
                        if let artist = album.artist {
                            Text(artist).font(.title3).foregroundStyle(.secondary)
                        }
                        if let year = album.year {
                            Text(String(year)).font(.callout).foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 20) {
                            Button { player.play(songs: songs, startIndex: 0) } label: {
                                Label(String(localized: "play"), systemImage: "play.fill")
                            }
                            Button { player.playShuffled(songs: songs) } label: {
                                Label(String(localized: "shuffle"), systemImage: "shuffle")
                            }
                        }
                        .disabled(songs.isEmpty)
                        .padding(.top, 8)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index) {
                        player.play(songs: songs, startIndex: index)
                    }
                }
            }
        }
        .task {
            songs = await LibraryStore.shared.albumSongs(album)
            isLoading = false
        }
    }
}
