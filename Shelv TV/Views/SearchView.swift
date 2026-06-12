import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var searchTask: Task<Void, Never>?

    private let player = AudioPlayerService.shared

    var body: some View {
        NavigationStack {
            List {
                if let artists = result?.artist, !artists.isEmpty {
                    Section(String(localized: "artists")) {
                        cardRow { ForEach(artists) { ArtistCard(artist: $0, size: 220) } }
                    }
                }
                if let albums = result?.album, !albums.isEmpty {
                    Section(String(localized: "albums")) {
                        cardRow { ForEach(albums) { AlbumCard(album: $0, size: 220) } }
                    }
                }
                if let songs = result?.song, !songs.isEmpty {
                    Section(String(localized: "songs")) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                            SongRow(song: song, index: i) {
                                player.play(songs: songs, startIndex: i)
                            }
                        }
                    }
                }
            }
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

    private func cardRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 40) { content() }
                .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .listRowBackground(Color.clear)
    }
}
