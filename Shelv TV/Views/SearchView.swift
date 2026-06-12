import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var searchTask: Task<Void, Never>?

    private let player = AudioPlayerService.shared
    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 40)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    if let result {
                        if let artists = result.artist, !artists.isEmpty {
                            section(String(localized: "artists")) {
                                LazyVGrid(columns: columns, spacing: 40) {
                                    ForEach(artists) { ArtistCard(artist: $0) }
                                }
                            }
                        }
                        if let albums = result.album, !albums.isEmpty {
                            section(String(localized: "albums")) {
                                LazyVGrid(columns: columns, spacing: 40) {
                                    ForEach(albums) { AlbumCard(album: $0) }
                                }
                            }
                        }
                        if let songs = result.song, !songs.isEmpty {
                            section(String(localized: "songs")) {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                                        SongRow(song: song, index: i) {
                                            player.play(songs: songs, startIndex: i)
                                        }
                                        if i < songs.count - 1 { Divider() }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(50)
            }
            .navigationTitle(String(localized: "search"))
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

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).bold()
            content()
        }
    }
}
