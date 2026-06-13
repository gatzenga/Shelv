import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var searchTask: Task<Void, Never>?
    @State private var path = NavigationPath()

    private let player = AudioPlayerService.shared

    var body: some View {
        // Bewusst EINE durchgehende vertikale Liste (Künstler → Alben → Titel als Zeilen):
        // verschachtelte horizontale Karussells in einem vertikalen ScrollView sind unter
        // `.searchable` auf tvOS eine Fokus-Falle (der Abwärts-Swipe kommt nicht heraus).
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let artists = result?.artist, !artists.isEmpty {
                        sectionHeader(String(localized: "artists"))
                        ForEach(artists) { artist in
                            ArtistListRow(artist: artist, albumCount: 0) { path.append(artist) }
                        }
                    }
                    if let albums = result?.album, !albums.isEmpty {
                        sectionHeader(String(localized: "albums"))
                        ForEach(albums) { album in
                            AlbumListRow(album: album) { path.append(album) }
                        }
                    }
                    if let songs = result?.song, !songs.isEmpty {
                        sectionHeader(String(localized: "songs"))
                        ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                            DetailSongRow(song: song, number: i, showArtwork: true) {
                                player.play(songs: songs, startIndex: i)
                            }
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollIndicators(.hidden)
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
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
        Text(title).font(.title3).bold()
            .padding(.horizontal, 50)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
