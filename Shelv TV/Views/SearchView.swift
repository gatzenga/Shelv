import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var searchTask: Task<Void, Never>?
    @State private var path = NavigationPath()
    @State private var recentSearches: [String] = []

    private let player = AudioPlayerService.shared

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        // Bewusst EINE durchgehende vertikale Liste (Künstler → Alben → Titel als Zeilen):
        // verschachtelte horizontale Karussells in einem vertikalen ScrollView sind unter
        // `.searchable` auf tvOS eine Fokus-Falle (der Abwärts-Swipe kommt nicht heraus).
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if trimmedQuery.isEmpty {
                        if !recentSearches.isEmpty {
                            sectionHeader(String(localized: "recent_searches"))
                            ForEach(recentSearches, id: \.self) { entry in
                                HStack(spacing: 20) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48)
                                    Text(entry)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .rowButton {
                                    selectSearchHistoryEntry(entry)
                                }
                            }

                            HStack(spacing: 20) {
                                Image(systemName: "trash")
                                    .frame(width: 48)
                                Text(String(localized: "clear_search_history"))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.red)
                            .padding(.top, 20)
                            .rowButton {
                                clearSearchHistory()
                            }
                        }
                    } else {
                        if let artists = result?.artist, !artists.isEmpty {
                            sectionHeader(String(localized: "artists"))
                            ForEach(artists) { artist in
                                ArtistListRow(artist: artist, albumCount: 0) {
                                    commitCurrentSearch()
                                    path.append(artist)
                                }
                            }
                        }
                        if let albums = result?.album, !albums.isEmpty {
                            sectionHeader(String(localized: "albums"))
                            ForEach(albums) { album in
                                AlbumListRow(album: album) {
                                    commitCurrentSearch()
                                    path.append(album)
                                }
                            }
                        }
                        if let songs = result?.song, !songs.isEmpty {
                            sectionHeader(String(localized: "songs"))
                            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                                DetailSongRow(song: song, number: i, showArtwork: true) {
                                    commitCurrentSearch()
                                    player.play(songs: songs, startIndex: i)
                                }
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
            .onSubmit(of: .search) {
                commitCurrentSearch()
            }
            .onAppear {
                reloadSearchHistory()
            }
            .onChange(of: serverStore.activeServerID) { _, _ in
                reloadSearchHistory()
            }
            .onChange(of: query) { _, q in
                searchTask?.cancel()
                let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    result = nil
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if Task.isCancelled { return }
                    result = try? await SubsonicAPIService.shared.search(query: trimmed)
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

    private func reloadSearchHistory() {
        recentSearches = SearchHistoryStore.entries(for: serverStore.activeServerID)
    }

    private func commitCurrentSearch() {
        recentSearches = SearchHistoryStore.record(
            query,
            for: serverStore.activeServerID
        )
    }

    private func selectSearchHistoryEntry(_ entry: String) {
        recentSearches = SearchHistoryStore.record(
            entry,
            for: serverStore.activeServerID
        )
        query = entry
    }

    private func clearSearchHistory() {
        recentSearches = SearchHistoryStore.clear(for: serverStore.activeServerID)
    }
}
