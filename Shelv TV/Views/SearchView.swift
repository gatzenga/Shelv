import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var searchTask: Task<Void, Never>?

    private let player = AudioPlayerService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let artists = result?.artist, !artists.isEmpty {
                        sectionHeader(String(localized: "artists"))
                        cardRow { ForEach(artists) { ArtistCard(artist: $0, size: 220) } }
                    }
                    if let albums = result?.album, !albums.isEmpty {
                        sectionHeader(String(localized: "albums"))
                        cardRow { ForEach(albums) { AlbumCard(album: $0, size: 220) } }
                    }
                    if let songs = result?.song, !songs.isEmpty {
                        sectionHeader(String(localized: "songs"))
                        LazyVStack(spacing: 4) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                                DetailSongRow(song: song, number: i, showArtwork: true) {
                                    player.play(songs: songs, startIndex: i)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollIndicators(.hidden)
            .searchable(text: $query, placement: .automatic)
            .onChange(of: query) { _, q in
                searchTask?.cancel()
                guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { result = nil; return }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if Task.isCancelled { return }
                    result = try? await SubsonicAPIService.shared.search(query: q)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.title3).bold().padding(.horizontal, 50)
    }

    private func cardRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 40) { content() }
                .padding(.horizontal, 50)
                .padding(.vertical, 20)
        }
        .scrollClipDisabled()
    }
}
