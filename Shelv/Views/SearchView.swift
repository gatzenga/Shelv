import Combine
import SwiftUI

private nonisolated struct OfflineSearchDownloadState: Equatable {
    let songIDs: Set<String>
    let albumIDs: Set<String>
    let artistNames: Set<String>

    init(snapshot: DownloadUIStateSnapshot) {
        songIDs = snapshot.songIDs
        albumIDs = snapshot.albumIDs
        artistNames = snapshot.artistNames
    }

    static let empty = OfflineSearchDownloadState(snapshot: .empty)
}

private struct SearchPresentationModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let usesSystemSearchTabActivation: Bool
    let placement: SearchFieldPlacement
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesSystemSearchTabActivation {
            content.searchable(
                text: $text,
                placement: placement,
                prompt: Text(prompt)
            )
        } else {
            content.searchable(
                text: $text,
                isPresented: $isPresented,
                placement: placement,
                prompt: Text(prompt)
            )
        }
    }
}

struct SearchView: View {
    /// Wird von ContentView bei jedem Tab-Wechsel zu Search erhöht → triggert Reset + Fokus.
    var resetToken: Int = 0
    var searchPlacement: SearchFieldPlacement = .navigationBarDrawer(displayMode: .always)
    var usesSystemSearchTabActivation = false
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject private var musicLibraries = MusicLibraryStore.shared
    @EnvironmentObject var serverStore: ServerStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage(PersonalizationPreferenceKey.showFavoritesInLibrary) private var showFavoritesInLibrary = true
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage("enableDownloads") private var enableDownloads = true
    @ObservedObject private var downloadStore = DownloadStore.shared

    @State private var query = ""
    @State private var searchFieldActive = false
    @State private var result: SearchResult?
    @State private var lyricsResults: [LyricsSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var appliedResetToken = 0
    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var currentToast: ShelveToast?
    @State private var artistToDeleteDownloads: Artist?
    @State private var albumToDeleteDownloads: Album?
    @State private var offlineDownloadState = OfflineSearchDownloadState.empty
    @State private var recentSearches: [String] = []

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchedFavoriteArtists: [Artist] {
        guard showFavoritesInLibrary, !query.isEmpty else { return [] }
        let q = query.lowercased()
        var base = libraryStore.starredArtists
        if offlineMode.isOffline {
            base = base.filter { offlineDownloadState.artistNames.contains($0.name) }
        }
        return base.filter { $0.name.lowercased().contains(q) }
    }

    private var matchedFavoriteAlbums: [Album] {
        guard showFavoritesInLibrary, !query.isEmpty else { return [] }
        let q = query.lowercased()
        var base = libraryStore.starredAlbums
        if offlineMode.isOffline {
            base = base.filter { offlineDownloadState.albumIDs.contains($0.id) }
        }
        return base.filter {
            $0.name.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) ?? false)
        }
    }

    private var matchedFavoriteSongs: [Song] {
        guard showFavoritesInLibrary, !query.isEmpty else { return [] }
        let q = query.lowercased()
        var base = libraryStore.starredSongs
        if offlineMode.isOffline {
            base = base.filter { offlineDownloadState.songIDs.contains($0.id) }
        }
        return base.filter {
            $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) ?? false)
        }
    }

    private var hasFavoriteResults: Bool {
        !matchedFavoriteArtists.isEmpty || !matchedFavoriteAlbums.isEmpty || !matchedFavoriteSongs.isEmpty
    }

    private var hasResults: Bool {
        !(result?.artist ?? []).isEmpty ||
        !(result?.album ?? []).isEmpty ||
        !(result?.song ?? []).isEmpty ||
        !lyricsResults.isEmpty ||
        hasFavoriteResults
    }

    private func applyResetTokenIfNeeded(_ token: Int) {
        guard token != 0, token != appliedResetToken else { return }
        appliedResetToken = token
        resetAndFocusSearch()
    }

    private func resetAndFocusSearch() {
        searchTask?.cancel()
        query = ""
        result = nil
        lyricsResults = []
        isSearching = false
        searchFieldActive = false

        guard !usesSystemSearchTabActivation else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            searchFieldActive = true
            try? await Task.sleep(for: .milliseconds(350))
            searchFieldActive = true
        }
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
        searchFieldActive = true
    }

    private func clearSearchHistory() {
        recentSearches = SearchHistoryStore.clear(for: serverStore.activeServerID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if trimmedQuery.isEmpty {
                    if recentSearches.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text(String(localized: "search_for_artists_albums_or_songs"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            Section {
                                ForEach(recentSearches, id: \.self) { entry in
                                    Button {
                                        selectSearchHistoryEntry(entry)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .foregroundStyle(.secondary)
                                            Text(entry)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                HStack {
                                    Text(String(localized: "recent_searches"))
                                    Spacer()
                                    Button {
                                        clearSearchHistory()
                                    } label: {
                                        Text(String(localized: "clear"))
                                            .textCase(nil)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(accentColor)
                                    .accessibilityLabel(String(localized: "clear_search_history"))
                                }
                                .textCase(nil)
                            }

                            Section {
                                PlayerBottomSpacer(activeHeight: 90, inactiveHeight: 0)
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollIndicators(.hidden)
                    }
                } else if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasResults {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        if let artists = result?.artist.map({ $0.filter { ($0.albumCount ?? 0) > 0 } }), !artists.isEmpty {
                            Section(String(localized: "artists")) {
                                ForEach(artists) { artist in
                                    ArtistDownloadAvailabilityReader(artistName: artist.name) { availability in
                                        NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                            HStack(spacing: 12) {
                                                AlbumArtView(coverArtId: artist.coverArt, size: 100, isCircle: true)
                                                    .frame(width: 44, height: 44)
                                                Text(artist.name)
                                                    .font(.body)
                                                Spacer()
                                                HStack(spacing: 4) {
                                                    ArtistFavoriteBadge(artistId: artist.id)
                                                    if enableDownloads && availability.isCatalogDownloaded {
                                                        DownloadAvailabilityIcon()
                                                    }
                                                }
                                            }
                                        }
                                        .simultaneousGesture(
                                            TapGesture().onEnded { commitCurrentSearch() }
                                        )
                                        .contextMenu {
                                            artistContextMenuItems(artist)
                                        }
                                        .personalizedAlbumArtistSwipeActions(
                                            isOffline: offlineMode.isOffline,
                                            isFavorite: libraryStore.isArtistStarred(artist),
                                            downloadState: artistDownloadState(for: artist),
                                            accentColor: accentColor,
                                            onFavorite: {
                                                haptic(.medium); Task { await libraryStore.toggleStarArtist(artist) }
                                            },
                                            onAddToPlaylist: {
                                                addArtistToPlaylist(artist)
                                            },
                                            onDownload: {
                                                handleArtistDownloadSwipe(artist)
                                            },
                                            onPlayNext: {
                                                haptic(); playNextArtist(artist)
                                            },
                                            onAddToQueue: {
                                                haptic(); queueArtist(artist)
                                            }
                                        )
                                    }
                                }
                            }
                        }

                        if let albums = result?.album, !albums.isEmpty {
                            Section(String(localized: "albums")) {
                                ForEach(albums) { album in
                                    AlbumDownloadStatusReader(
                                        albumID: album.id,
                                        totalSongs: album.songCount ?? 0,
                                        tracksIntermediateProgress: false
                                    ) { downloadStatus in
                                        NavigationLink(destination: AlbumDetailView(album: album)) {
                                            HStack(spacing: 12) {
                                                AlbumArtView(coverArtId: album.coverArt, size: 100, cornerRadius: 8)
                                                    .frame(width: 44, height: 44)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(album.name).font(.body)
                                                    if let artist = album.artist {
                                                        Text(artist)
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                Spacer()
                                                HStack(spacing: 4) {
                                                    AlbumFavoriteBadge(albumId: album.id)
                                                    AlbumDownloadBadge(albumId: album.id, style: .list)
                                                }
                                            }
                                        }
                                        .simultaneousGesture(
                                            TapGesture().onEnded { commitCurrentSearch() }
                                        )
                                        .albumContextMenu(album, showPreview: false)
                                        .personalizedAlbumArtistSwipeActions(
                                            isOffline: offlineMode.isOffline,
                                            isFavorite: libraryStore.isAlbumStarred(album),
                                            downloadState: albumDownloadState(downloadStatus),
                                            accentColor: accentColor,
                                            onFavorite: {
                                                haptic(.medium); Task { await libraryStore.toggleStarAlbum(album) }
                                            },
                                            onAddToPlaylist: {
                                                addAlbumToPlaylist(album)
                                            },
                                            onDownload: {
                                                handleAlbumDownloadSwipe(album)
                                            },
                                            onPlayNext: {
                                                haptic(); playNextAlbum(album)
                                            },
                                            onAddToQueue: {
                                                haptic(); queueAlbum(album)
                                            }
                                        )
                                    }
                                }
                            }
                        }

                        if let songs = result?.song, !songs.isEmpty {
                            Section(String(localized: "songs")) {
                                ForEach(songs) { song in
                                    Button {
                                        commitCurrentSearch()
                                        player.playSong(song)
                                    } label: {
                                        HStack(spacing: 12) {
                                            AlbumArtView(coverArtId: song.coverArt, size: 100, cornerRadius: 8)
                                                .frame(width: 44, height: 44)
                                                .overlay {
                                                    NowPlayingOverlay(
                                                        songId: song.id, size: 44,
                                                        cornerRadius: 8, accentColor: accentColor
                                                    )
                                                }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(song.title)
                                                    .font(.body)
                                                    .foregroundStyle(.primary)
                                                if let artist = song.artist {
                                                    Text(artist)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            HStack(spacing: 4) {
                                                SongFavoriteBadge(songId: song.id)
                                                DownloadStatusIcon(songId: song.id)
                                            }
                                            Text(song.durationFormatted)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .personalizedSongSwipeActions(
                                        song: song,
                                        isOffline: offlineMode.isOffline,
                                        isFavorite: libraryStore.isSongStarred(song),
                                        accentColor: accentColor,
                                        onPlay: {
                                            player.playSong(song)
                                        },
                                        onFavorite: {
                                            haptic(.medium)
                                            Task { await libraryStore.toggleStarSong(song) }
                                        },
                                        onAddToPlaylist: {
                                            playlistSongIds = [song.id]
                                            showAddToPlaylist = true
                                        },
                                        onPlayNext: {
                                            haptic()
                                            player.addPlayNext(song)
                                            currentToast = ShelveToast(message: String(localized: "plays_next"))
                                        },
                                        onAddToQueue: {
                                            haptic()
                                            player.addToQueue(song)
                                            currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                                        }
                                    )
                                }
                            }
                        }
                        if !lyricsResults.isEmpty {
                            Section(String(localized: "lyrics")) {
                                ForEach(lyricsResults) { item in
                                    let song = Song(
                                        id: item.songId,
                                        title: item.songTitle ?? item.songId,
                                        artist: item.artistName, album: nil, albumId: nil,
                                        track: nil, discNumber: nil, duration: item.duration, coverArt: item.coverArt,
                                        year: nil, genre: nil, playCount: nil,
                                        starred: nil, suffix: nil, bitRate: nil, replayGain: nil
                                    )
                                    Button {
                                        commitCurrentSearch()
                                        playLyricsResult(item)
                                    } label: {
                                        HStack(spacing: 12) {
                                            AlbumArtView(coverArtId: item.coverArt, size: 100, cornerRadius: 8)
                                                .frame(width: 44, height: 44)
                                                .overlay {
                                                    NowPlayingOverlay(
                                                        songId: item.songId, size: 44,
                                                        cornerRadius: 8, accentColor: accentColor
                                                    )
                                                }
                                            VStack(alignment: .leading, spacing: 2) {
                                                let songTitle = item.songTitle ?? String(localized: "unknown_song")
                                                let songTitleColor: Color = item.songTitle != nil ? .primary : .secondary
                                                Text(songTitle)
                                                    .font(.body)
                                                    .foregroundStyle(songTitleColor)
                                                if let artist = item.artistName {
                                                    Text(artist)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                highlightedLyricsSnippet(
                                                    item.snippet,
                                                    query: query,
                                                    accentColor: accentColor
                                                )
                                                    .font(.caption2)
                                                    .lineLimit(1)
                                                    .italic()
                                            }
                                            Spacer()
                                            HStack(spacing: 4) {
                                                SongFavoriteBadge(songId: item.songId)
                                                DownloadStatusIcon(songId: item.songId)
                                            }
                                            if let dur = item.duration {
                                                Text(String(format: "%d:%02d", dur / 60, dur % 60))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .monospacedDigit()
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .personalizedSongSwipeActions(
                                        song: song,
                                        isOffline: offlineMode.isOffline,
                                        isFavorite: libraryStore.isSongStarred(song),
                                        accentColor: accentColor,
                                        onPlay: {
                                            playLyricsResult(item)
                                        },
                                        onFavorite: {
                                            haptic(.medium)
                                            Task { await libraryStore.toggleStarSong(song) }
                                        },
                                        onAddToPlaylist: {
                                            playlistSongIds = [item.songId]
                                            showAddToPlaylist = true
                                        },
                                        onPlayNext: {
                                            haptic()
                                            player.addPlayNext(song)
                                            currentToast = ShelveToast(message: String(localized: "plays_next"))
                                        },
                                        onAddToQueue: {
                                            haptic()
                                            player.addToQueue(song)
                                            currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                                        }
                                    )
                                }
                            }
                        }

                        if hasFavoriteResults {
                            Section(String(localized: "favorites")) {
                                ForEach(matchedFavoriteArtists) { artist in
                                    ArtistDownloadAvailabilityReader(artistName: artist.name) { availability in
                                        NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                            HStack(spacing: 12) {
                                                AlbumArtView(coverArtId: artist.coverArt, size: 100, isCircle: true)
                                                    .frame(width: 44, height: 44)
                                                Text(artist.name).font(.body)
                                                Spacer()
                                                HStack(spacing: 4) {
                                                    ArtistFavoriteBadge(artistId: artist.id)
                                                    if enableDownloads && availability.isCatalogDownloaded {
                                                        DownloadAvailabilityIcon()
                                                    }
                                                }
                                            }
                                        }
                                        .simultaneousGesture(
                                            TapGesture().onEnded { commitCurrentSearch() }
                                        )
                                        .contextMenu {
                                            artistContextMenuItems(artist)
                                        }
                                        .personalizedAlbumArtistSwipeActions(
                                            isOffline: offlineMode.isOffline,
                                            isFavorite: true,
                                            downloadState: artistDownloadState(for: artist),
                                            accentColor: accentColor,
                                            onFavorite: {
                                                haptic(.medium); Task { await libraryStore.toggleStarArtist(artist) }
                                            },
                                            onAddToPlaylist: {
                                                addArtistToPlaylist(artist)
                                            },
                                            onDownload: {
                                                handleArtistDownloadSwipe(artist)
                                            },
                                            onPlayNext: {
                                                haptic(); playNextArtist(artist)
                                            },
                                            onAddToQueue: {
                                                haptic(); queueArtist(artist)
                                            }
                                        )
                                    }
                                }
                                ForEach(matchedFavoriteAlbums) { album in
                                    AlbumDownloadStatusReader(
                                        albumID: album.id,
                                        totalSongs: album.songCount ?? 0,
                                        tracksIntermediateProgress: false
                                    ) { downloadStatus in
                                        NavigationLink(destination: AlbumDetailView(album: album)) {
                                            HStack(spacing: 12) {
                                                AlbumArtView(coverArtId: album.coverArt, size: 100, cornerRadius: 8)
                                                    .frame(width: 44, height: 44)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(album.name).font(.body)
                                                    if let artist = album.artist {
                                                        Text(artist).font(.caption).foregroundStyle(.secondary)
                                                    }
                                                }
                                                Spacer()
                                                HStack(spacing: 4) {
                                                    AlbumFavoriteBadge(albumId: album.id)
                                                    AlbumDownloadBadge(albumId: album.id, style: .list)
                                                }
                                            }
                                        }
                                        .simultaneousGesture(
                                            TapGesture().onEnded { commitCurrentSearch() }
                                        )
                                        .albumContextMenu(album, showPreview: false)
                                        .personalizedAlbumArtistSwipeActions(
                                            isOffline: offlineMode.isOffline,
                                            isFavorite: true,
                                            downloadState: albumDownloadState(downloadStatus),
                                            accentColor: accentColor,
                                            onFavorite: {
                                                haptic(.medium); Task { await libraryStore.toggleStarAlbum(album) }
                                            },
                                            onAddToPlaylist: {
                                                addAlbumToPlaylist(album)
                                            },
                                            onDownload: {
                                                handleAlbumDownloadSwipe(album)
                                            },
                                            onPlayNext: {
                                                haptic(); playNextAlbum(album)
                                            },
                                            onAddToQueue: {
                                                haptic(); queueAlbum(album)
                                            }
                                        )
                                    }
                                }
                                ForEach(matchedFavoriteSongs) { song in
                                    Button {
                                        commitCurrentSearch()
                                        player.playSong(song)
                                    } label: {
                                        HStack(spacing: 12) {
                                            AlbumArtView(coverArtId: song.coverArt, size: 100, cornerRadius: 8)
                                                .frame(width: 44, height: 44)
                                                .overlay {
                                                    NowPlayingOverlay(songId: song.id, size: 44, cornerRadius: 8, accentColor: accentColor)
                                                }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(song.title).font(.body).foregroundStyle(.primary)
                                                if let artist = song.artist {
                                                    Text(artist).font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            HStack(spacing: 4) {
                                                SongFavoriteBadge(songId: song.id)
                                                DownloadStatusIcon(songId: song.id)
                                            }
                                            Text(song.durationFormatted)
                                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .personalizedSongSwipeActions(
                                        song: song,
                                        isOffline: offlineMode.isOffline,
                                        isFavorite: true,
                                        accentColor: accentColor,
                                        onPlay: {
                                            player.playSong(song)
                                        },
                                        onFavorite: {
                                            haptic(.medium)
                                            Task { await libraryStore.toggleStarSong(song) }
                                        },
                                        onAddToPlaylist: {
                                            playlistSongIds = [song.id]
                                            showAddToPlaylist = true
                                        },
                                        onPlayNext: {
                                            haptic()
                                            player.addPlayNext(song)
                                            currentToast = ShelveToast(message: String(localized: "plays_next"))
                                        },
                                        onAddToQueue: {
                                            haptic()
                                            player.addToQueue(song)
                                            currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                                        }
                                    )
                                }
                            }
                        }

                        Section {
                            PlayerBottomSpacer(activeHeight: 90, inactiveHeight: 0)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle(String(localized: "search"))
            .modifier(SearchPresentationModifier(
                text: $query,
                isPresented: $searchFieldActive,
                usesSystemSearchTabActivation: usesSystemSearchTabActivation,
                placement: searchPlacement,
                prompt: String(localized: "artists_albums_songs")
            ))
            .onSubmit(of: .search) {
                commitCurrentSearch()
            }
            .onAppear {
                applyResetTokenIfNeeded(resetToken)
                reloadSearchHistory()
                if offlineMode.isOffline {
                    offlineDownloadState = OfflineSearchDownloadState(
                        snapshot: DownloadUIStateHub.shared.currentSnapshot
                    )
                }
            }
            .onChange(of: resetToken) { _, newValue in
                applyResetTokenIfNeeded(newValue)
            }
            .onChange(of: serverStore.activeServerID) { _, _ in
                restartSearchAfterServerChange()
            }
            .onChange(of: serverStore.activeServerRevision) { _, _ in
                restartSearchAfterServerChange()
            }
            .onChange(of: musicLibraries.revision) { _, _ in
                guard !offlineMode.isOffline else { return }
                searchTask?.cancel()
                let trimmed = trimmedQuery
                guard !trimmed.isEmpty else { return }
                result = nil
                lyricsResults = []
                searchTask = Task {
                    await performSearch(query: trimmed)
                }
            }
            .onChange(of: offlineMode.isOffline) { _, isOffline in
                guard isOffline else { return }
                offlineDownloadState = OfflineSearchDownloadState(
                    snapshot: DownloadUIStateHub.shared.currentSnapshot
                )
            }
            .onReceive(
                DownloadUIStateHub.shared.stateChanges
            ) { _ in
                guard offlineMode.isOffline else { return }
                offlineDownloadState = OfflineSearchDownloadState(
                    snapshot: DownloadUIStateHub.shared.currentSnapshot
                )
            }
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    result = nil
                    lyricsResults = []
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    await performSearch(query: trimmed)
                }
            }
            .shelveToast($currentToast)
            .alert(
                String(localized: "delete_downloads"),
                isPresented: Binding(get: { artistToDeleteDownloads != nil }, set: { if !$0 { artistToDeleteDownloads = nil } }),
                presenting: artistToDeleteDownloads
            ) { artist in
                Button(String(localized: "delete"), role: .destructive) {
                    if let match = downloadStore.artists.first(where: {
                        $0.artistId == artist.id || $0.name == artist.name
                    }) {
                        downloadStore.deleteArtist(match.artistId)
                    }
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
            }
            .alert(
                String(localized: "delete_downloads"),
                isPresented: Binding(get: { albumToDeleteDownloads != nil }, set: { if !$0 { albumToDeleteDownloads = nil } }),
                presenting: albumToDeleteDownloads
            ) { album in
                Button(String(localized: "delete"), role: .destructive) {
                    downloadStore.deleteAlbum(album.id)
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
            }
            .alert(String(localized: "error"), isPresented: $showError, presenting: errorMessage) { _ in
                Button(String(localized: "ok"), role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
            .sheet(isPresented: $showAddToPlaylist) {
                AddToPlaylistSheet(songIds: playlistSongIds)
                    .environmentObject(libraryStore)
                    .tint(accentColor)
            }
        }
    }

    private func queueArtist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            player.addToQueue(songs)
            currentToast = ShelveToast(message: String(localized: "added_to_queue"))
        }
    }

    private func playNextArtist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            player.addPlayNext(songs)
            currentToast = ShelveToast(message: String(localized: "plays_next"))
        }
    }

    private func addArtistToPlaylist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            await MainActor.run {
                playlistSongIds = songs.map(\.id)
                showAddToPlaylist = true
            }
        }
    }

    private func artistDownloadState(for artist: Artist) -> PersonalizedDownloadSwipeState {
        guard enableDownloads else { return .hidden }
        switch downloadStore.artistDownloadStatus(
            artist: artist,
            catalogAlbums: libraryStore.albums
        ) {
        case .none, .partial:
            return offlineMode.isOffline ? .hidden : .download
        case .complete:
            return .delete
        }
    }

    private func handleArtistDownloadSwipe(_ artist: Artist) {
        guard enableDownloads else { return }
        switch downloadStore.artistDownloadStatus(
            artist: artist,
            catalogAlbums: libraryStore.albums
        ) {
        case .none, .partial:
            guard !offlineMode.isOffline else { return }
            haptic()
            let sid = serverStore.activeServer?.stableId ?? ""
            Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
        case .complete:
            haptic(); artistToDeleteDownloads = artist
        }
    }

    @ViewBuilder
    private func artistInstantMixMenuItem(_ artist: Artist) -> some View {
        if showInstantMixActions && !offlineMode.isOffline {
            Button {
                playInstantMix(artist: artist)
            } label: {
                Label(String(localized: "instant_mix"), systemImage: "sparkles")
            }
        }
    }

    @ViewBuilder
    private func artistContextMenuItems(_ artist: Artist) -> some View {
        artistInstantMixMenuItem(artist)

        if enableDownloads {
            Divider()
            let downloadStatus = downloadStore.artistDownloadStatus(
                artist: artist,
                catalogAlbums: libraryStore.albums
            )
            switch downloadStatus {
            case .none:
                if !offlineMode.isOffline {
                    Button {
                        let sid = serverStore.activeServer?.stableId ?? ""
                        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
                    } label: {
                        Label(String(localized: "download_artist"), systemImage: "arrow.down.circle")
                    }
                }
            case .partial:
                if !offlineMode.isOffline {
                    Button {
                        let sid = serverStore.activeServer?.stableId ?? ""
                        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
                    } label: {
                        Label(String(localized: "download_remaining"), systemImage: "arrow.down.circle")
                    }
                }
                Button(
                    String(localized: "delete_downloads_2"),
                    systemImage: DownloadActionSymbols.delete,
                    role: .destructive
                ) {
                    artistToDeleteDownloads = artist
                }
                .tint(.red)
            case .complete:
                Button(
                    String(localized: "delete_downloads_2"),
                    systemImage: DownloadActionSymbols.delete,
                    role: .destructive
                ) {
                    artistToDeleteDownloads = artist
                }
                .tint(.red)
            }
        }
    }

    private func playInstantMix(artist: Artist) {
        InstantMixService.playArtistMix(for: artist, player: player)
    }

    private func queueAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.addToQueue(songs)
                currentToast = ShelveToast(message: String(localized: "added_to_queue"))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func playNextAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.addPlayNext(songs)
                currentToast = ShelveToast(message: String(localized: "plays_next"))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func addAlbumToPlaylist(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                playlistSongIds = songs.map(\.id)
                showAddToPlaylist = true
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func albumDownloadState(_ status: AlbumDownloadStatus) -> PersonalizedDownloadSwipeState {
        guard enableDownloads else { return .hidden }
        if status != .none {
            return .delete
        }
        return offlineMode.isOffline ? .hidden : .download
    }

    private func handleAlbumDownloadSwipe(_ album: Album) {
        guard enableDownloads else { return }
        if DownloadUIStateHub.shared.isAlbumDownloaded(album.id) {
            haptic(); albumToDeleteDownloads = album
        } else if !offlineMode.isOffline {
            haptic()
            Task { await DownloadService.shared.enqueueAlbum(album: album, serverId: serverStore.activeServer?.stableId ?? "") }
        }
    }

    private func playLyricsResult(_ item: LyricsSearchResult) {
        Task {
            if let song = try? await SubsonicAPIService.shared.getSong(id: item.songId) {
                player.playSong(song)
                // Metadaten in DB nachfüllen, damit künftige Suchen den echten Namen zeigen
                if item.songTitle == nil || item.artistName == nil || item.coverArt == nil || item.duration == nil,
                   let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString {
                    Task.detached(priority: .utility) {
                        await LyricsService.shared.updateMetadata(
                            songId: item.songId, serverId: serverId,
                            title: song.title, artist: song.artist,
                            albumId: song.albumId, coverArt: song.coverArt,
                            duration: song.duration
                        )
                    }
                }
            } else {
                // Fallback: mit vorhandenen Daten abspielen
                let song = Song(
                    id: item.songId,
                    title: item.songTitle ?? item.songId,
                    artist: item.artistName, album: nil, albumId: nil,
                    track: nil, discNumber: nil, duration: nil, coverArt: item.coverArt,
                    year: nil, genre: nil, playCount: nil,
                    starred: nil, suffix: nil, bitRate: nil, replayGain: nil
                )
                player.playSong(song)
            }
        }
    }

    private func performSearch(query: String) async {
        let requestedServerID = serverStore.activeServerID
        let requestedServerRevision = serverStore.activeServerRevision
        let selectionRevision = musicLibraries.revision
        isSearching = true
        if offlineMode.isOffline {
            await performOfflineSearch(query: query)
            if requestedServerID == serverStore.activeServerID,
               requestedServerRevision == serverStore.activeServerRevision {
                isSearching = false
            }
            return
        }
        do {
            let response = try await SubsonicAPIService.shared.search(query: query)
            guard !Task.isCancelled,
                  requestedServerID == serverStore.activeServerID,
                  requestedServerRevision == serverStore.activeServerRevision,
                  selectionRevision == musicLibraries.revision,
                  query == trimmedQuery
            else {
                return
            }
            result = response
        } catch {
            let isCancelled = error is CancellationError
                || (error as? URLError)?.code == .cancelled
            if isCancelled {
                if requestedServerID == serverStore.activeServerID,
                   requestedServerRevision == serverStore.activeServerRevision,
                   selectionRevision == musicLibraries.revision,
                   query == trimmedQuery {
                    isSearching = false
                }
                return
            }
            guard requestedServerID == serverStore.activeServerID,
                  requestedServerRevision == serverStore.activeServerRevision,
                  selectionRevision == musicLibraries.revision,
                  query == trimmedQuery
            else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
        guard !Task.isCancelled,
              requestedServerID == serverStore.activeServerID,
              requestedServerRevision == serverStore.activeServerRevision,
              selectionRevision == musicLibraries.revision,
              query == trimmedQuery
        else {
            return
        }
        isSearching = false
        if let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString {
            var results = await LyricsService.shared.searchLyrics(text: query, serverId: serverId)
            let selection = musicLibraries.snapshot
            if selection.appliesFilter,
               let folderIDs = selection.visibleCacheFolderIDs {
                let visibleAlbumIDs = await LibraryRepository.shared.visibleAlbumIDs(
                    serverKey: serverId,
                    libraryIDs: folderIDs
                )
                results = await LyricsLibraryFilter.visibleResults(
                    results,
                    visibleAlbumIDs: visibleAlbumIDs,
                    serverId: serverId
                )
            }
            guard !Task.isCancelled,
                  requestedServerID == serverStore.activeServerID,
                  requestedServerRevision == serverStore.activeServerRevision,
                  selectionRevision == musicLibraries.revision,
                  query == trimmedQuery
            else { return }
            lyricsResults = results
            let missing = results.filter { $0.songTitle == nil || $0.duration == nil }
            if !missing.isEmpty {
                for item in missing {
                    guard !Task.isCancelled,
                          requestedServerID == serverStore.activeServerID,
                          requestedServerRevision == serverStore.activeServerRevision
                    else { break }
                    guard let song = try? await SubsonicAPIService.shared.getSong(id: item.songId) else { continue }
                    guard requestedServerID == serverStore.activeServerID,
                          requestedServerRevision == serverStore.activeServerRevision
                    else { break }
                    await LyricsService.shared.updateMetadata(
                        songId: item.songId, serverId: serverId,
                        title: song.title, artist: song.artist,
                        albumId: song.albumId, coverArt: song.coverArt,
                        duration: song.duration
                    )
                    if let idx = lyricsResults.firstIndex(where: { $0.songId == item.songId }) {
                        lyricsResults[idx] = LyricsSearchResult(
                            songId: item.songId,
                            songTitle: song.title, artistName: song.artist,
                            albumId: song.albumId,
                            coverArt: song.coverArt, snippet: item.snippet,
                            duration: song.duration
                        )
                    }
                }
            }
        }
    }

    private func performOfflineSearch(query: String) async {
        let requestedServerID = serverStore.activeServerID
        let requestedServerRevision = serverStore.activeServerRevision
        guard let sid = serverStore.activeServer?.stableId, !sid.isEmpty else {
            result = SearchResult(artist: [], album: [], song: [])
            lyricsResults = []
            return
        }
        let records = await DownloadDatabase.shared.search(serverId: sid, query: query, limit: 100)
        guard requestedServerID == serverStore.activeServerID,
              requestedServerRevision == serverStore.activeServerRevision
        else { return }
        let songs = records.map { $0.toDownloadedSong().asSong() }
        let q = query.lowercased()
        let matchedAlbums = DownloadStore.shared.albums
            .filter { $0.title.lowercased().contains(q) || $0.artistName.lowercased().contains(q) }
            .map { $0.asAlbum() }
        let matchedArtists = DownloadStore.shared.artists
            .filter { $0.name.lowercased().contains(q) }
            .map { $0.asArtist() }
        result = SearchResult(artist: matchedArtists, album: matchedAlbums, song: songs)
        let lyricsSid = serverStore.activeServer?.id.uuidString ?? sid
        let allLyrics = await LyricsService.shared.searchLyrics(text: query, serverId: lyricsSid)
        guard requestedServerID == serverStore.activeServerID,
              requestedServerRevision == serverStore.activeServerRevision
        else { return }
        let downloadedIds = Set(DownloadStore.shared.songs.map { $0.songId })
        lyricsResults = allLyrics.filter { downloadedIds.contains($0.songId) }
    }

    private func restartSearchAfterServerChange() {
        searchTask?.cancel()
        result = nil
        lyricsResults = []
        isSearching = false
        reloadSearchHistory()
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else { return }
        searchTask = Task {
            await performSearch(query: trimmed)
        }
    }

    private func highlightedLyricsSnippet(_ snippet: String, query: String, accentColor: Color) -> Text {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty, !needle.isEmpty else {
            return Text(snippet).foregroundStyle(.tertiary)
        }

        var output = Text("")
        var searchStart = snippet.startIndex

        while searchStart < snippet.endIndex,
              let range = snippet.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<snippet.endIndex
              ) {
            if searchStart < range.lowerBound {
                output = output + Text(String(snippet[searchStart..<range.lowerBound]))
                    .foregroundStyle(.tertiary)
            }
            output = output + Text(String(snippet[range]))
                .foregroundStyle(accentColor)
                .bold()
            searchStart = range.upperBound
        }

        if searchStart < snippet.endIndex {
            output = output + Text(String(snippet[searchStart..<snippet.endIndex]))
                .foregroundStyle(.tertiary)
        }

        return output
    }
}
