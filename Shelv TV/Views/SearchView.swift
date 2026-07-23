import SwiftUI
import UIKit

struct SearchView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @ObservedObject private var musicLibraries = MusicLibraryStore.shared
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var searchTask: Task<Void, Never>?
    @State private var path = NavigationPath()
    @State private var recentSearches: [String] = []
    @State private var automaticallyRecordedQuery: String?
    @State private var historyQueryAwaitingCursorPlacement: String?
    @State private var activeSearchTextField: UITextField?
    @FocusState private var isClearSearchHistoryFocused: Bool

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
                                HStack(spacing: 4) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48)
                                    Text(entry)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .rowButton(contentHorizontalPadding: 8) {
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
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background {
                                        Capsule()
                                            .fill(
                                                isClearSearchHistoryFocused
                                                    ? Color.red.opacity(0.18)
                                                    : Color.clear
                                            )
                                    }
                                }
                                .buttonStyle(PlainRowButtonStyle())
                                .focused($isClearSearchHistoryFocused)
                                .animation(
                                    .easeOut(duration: 0.14),
                                    value: isClearSearchHistoryFocused
                                )

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
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UITextField.textDidBeginEditingNotification
                )
            ) { notification in
                guard let searchTextField = notification.object as? UITextField else {
                    return
                }
                activeSearchTextField = searchTextField
                guard let expectedQuery = historyQueryAwaitingCursorPlacement,
                      searchTextField.text == expectedQuery
                else { return }
                placeCursorAtEndAfterViewUpdate(
                    in: searchTextField,
                    matching: expectedQuery
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UITextField.textDidEndEditingNotification
                )
            ) { notification in
                guard let searchTextField = notification.object as? UITextField,
                      searchTextField === activeSearchTextField
                else { return }
                activeSearchTextField = nil
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
                if let expectedQuery = historyQueryAwaitingCursorPlacement,
                   q != expectedQuery {
                    historyQueryAwaitingCursorPlacement = nil
                }
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
        historyQueryAwaitingCursorPlacement = entry
        query = entry
        if let activeSearchTextField {
            placeCursorAtEndAfterViewUpdate(
                in: activeSearchTextField,
                matching: entry
            )
        }
    }

    private func clearSearchHistory() {
        recentSearches = SearchHistoryStore.clear(for: serverStore.activeServerID)
        automaticallyRecordedQuery = nil
    }

    private func placeCursorAtEndAfterViewUpdate(
        in textField: UITextField,
        matching expectedQuery: String
    ) {
        Task { @MainActor in
            await Task.yield()
            guard historyQueryAwaitingCursorPlacement == expectedQuery,
                  textField.text == expectedQuery
            else { return }
            placeCursorAtEnd(in: textField)
        }
    }

    private func placeCursorAtEnd(in textField: UITextField) {
        let end = textField.endOfDocument
        textField.selectedTextRange = textField.textRange(from: end, to: end)
    }

    private func restartSearchAfterServerChange() {
        searchTask?.cancel()
        result = nil
        automaticallyRecordedQuery = nil
        historyQueryAwaitingCursorPlacement = nil
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
