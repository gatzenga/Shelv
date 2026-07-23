import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @ObservedObject private var musicLibraries = MusicLibraryStore.shared
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var searchTask: Task<Void, Never>?
    @State private var path = NavigationPath()
    @State private var recentSearches: [String] = []
    @State private var automaticallyRecordedQuery: String?

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
                            sectionHeader(
                                String(localized: "recent_searches"),
                                topPadding: 0
                            )
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

                            HStack {
                                Button(role: .destructive) {
                                    clearSearchHistory()
                                } label: {
                                    Label(
                                        String(localized: "clear_search_history"),
                                        systemImage: "trash"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 20)
                            .focusSection()
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
                .padding(.top, 8)
                .padding(.bottom, 24)
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
                restartSearchAfterServerChange()
            }
            .onChange(of: serverStore.activeServerRevision) { _, _ in
                restartSearchAfterServerChange()
            }
            .onChange(of: musicLibraries.revision) { _, _ in
                guard !OfflineModeService.shared.isOffline else { return }
                searchTask?.cancel()
                let trimmed = trimmedQuery
                guard !trimmed.isEmpty else { return }
                result = nil
                let selectionRevision = musicLibraries.revision
                let requestedServerID = serverStore.activeServerID
                let requestedServerRevision = serverStore.activeServerRevision
                searchTask = Task {
                    let response = try? await SubsonicAPIService.shared.search(query: trimmed)
                    guard !Task.isCancelled,
                          requestedServerID == serverStore.activeServerID,
                          requestedServerRevision == serverStore.activeServerRevision,
                          selectionRevision == musicLibraries.revision,
                          trimmed == trimmedQuery
                    else { return }
                    result = response
                    if response != nil {
                        recordCompletedSearch(trimmed)
                    }
                }
            }
            .onChange(of: query) { _, q in
                searchTask?.cancel()
                let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    result = nil
                    automaticallyRecordedQuery = nil
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if Task.isCancelled { return }
                    let selectionRevision = musicLibraries.revision
                    let requestedServerID = serverStore.activeServerID
                    let requestedServerRevision = serverStore.activeServerRevision
                    let response = try? await SubsonicAPIService.shared.search(query: trimmed)
                    guard !Task.isCancelled,
                          requestedServerID == serverStore.activeServerID,
                          requestedServerRevision == serverStore.activeServerRevision,
                          selectionRevision == musicLibraries.revision,
                          trimmed == trimmedQuery
                    else { return }
                    result = response
                    if response != nil {
                        recordCompletedSearch(trimmed)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, topPadding: CGFloat = 20) -> some View {
        Text(title).font(.title3).bold()
            .padding(.horizontal, 12)
            .padding(.top, topPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reloadSearchHistory() {
        recentSearches = SearchHistoryStore.entries(for: serverStore.activeServerID)
    }

    private func commitCurrentSearch() {
        let update = SearchHistoryStore.recordAutomatically(
            query,
            replacing: automaticallyRecordedQuery,
            for: serverStore.activeServerID
        )
        recentSearches = update.entries
        automaticallyRecordedQuery = nil
    }

    private func recordCompletedSearch(_ query: String) {
        let update = SearchHistoryStore.recordAutomatically(
            query,
            replacing: automaticallyRecordedQuery,
            for: serverStore.activeServerID
        )
        recentSearches = update.entries
        automaticallyRecordedQuery = update.provisionalQuery
    }

    private func selectSearchHistoryEntry(_ entry: String) {
        recentSearches = SearchHistoryStore.record(
            entry,
            for: serverStore.activeServerID
        )
        automaticallyRecordedQuery = nil
        query = entry
    }

    private func clearSearchHistory() {
        recentSearches = SearchHistoryStore.clear(for: serverStore.activeServerID)
        automaticallyRecordedQuery = nil
    }

    private func restartSearchAfterServerChange() {
        searchTask?.cancel()
        result = nil
        automaticallyRecordedQuery = nil
        reloadSearchHistory()
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else { return }
        let requestedServerID = serverStore.activeServerID
        let requestedServerRevision = serverStore.activeServerRevision
        searchTask = Task {
            let response = try? await SubsonicAPIService.shared.search(query: trimmed)
            guard !Task.isCancelled,
                  requestedServerID == serverStore.activeServerID,
                  requestedServerRevision == serverStore.activeServerRevision,
                  trimmed == trimmedQuery
            else { return }
            result = response
            if response != nil {
                recordCompletedSearch(trimmed)
            }
        }
    }
}
