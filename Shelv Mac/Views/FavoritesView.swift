import SwiftUI

enum FavoritesScope: Hashable {
    case overview
    case albums
    case songs
    case artists
}

struct FavoritesView: View {
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @EnvironmentObject var appState: AppState
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject private var personalizationVisibility = MacPersonalizationVisibilityStore.shared
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false
    @Environment(\.themeColor) private var themeColor
    @State private var searchText: String = ""
    @State private var playbackTask: Task<Void, Never>?
    @State private var isPreparingPlayback = false
    private let scope: FavoritesScope

    private var showPlaylistActions: Bool {
        personalizationVisibility.showPlaylistActions
    }

    init() {
        scope = .overview
    }

    init(scope: FavoritesScope) {
        self.scope = scope
    }

    private var effectiveShowDownloadsOnly: Bool {
        offlineMode.isOffline || showDownloadsOnly
    }

    /// The filter field only exists on the overview, so the dedicated
    /// albums/songs/artists pages keep showing everything.
    private var activeQuery: String {
        guard scope == .overview else { return "" }
        return searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(_ values: String?...) -> Bool {
        let query = activeQuery
        guard !query.isEmpty else { return true }
        return values.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    private var visibleArtists: [Artist] {
        var artists = libraryStore.starredArtists
        if effectiveShowDownloadsOnly {
            let downloadedNames = Set(downloadStore.artists.map(\.name))
            artists = artists.filter { downloadedNames.contains($0.name) }
        }
        return artists.filter { matches($0.name) }
    }

    private var visibleAlbums: [Album] {
        var albums = libraryStore.starredAlbums
        if effectiveShowDownloadsOnly {
            let downloadedIds = Set(downloadStore.albums.map(\.albumId))
            albums = albums.filter { downloadedIds.contains($0.id) }
        }
        return albums.filter { matches($0.name, $0.artist) }
    }

    private var visibleSongs: [Song] {
        var songs = libraryStore.starredSongs
        if effectiveShowDownloadsOnly {
            songs = songs.filter { downloadStore.isDownloaded(songId: $0.id) }
        }
        return songs.filter { matches($0.title, $0.artist, $0.album) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if scope == .overview {
                HStack {
                    TextField(String(localized: "filter"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160, idealWidth: 220, maxWidth: 220)
                    Spacer()
                    playbackButtons
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)

                Divider()
            }
            ScrollView {
                favoritesContent
            }
        }
        .navigationTitle(navigationTitle)
        .task { await libraryStore.loadStarred() }
        .onDisappear { cancelPlaybackPreparation() }
    }

    /// Shuffle only: favorites have no meaningful order of their own, and playing
    /// them straight through would alternate a single track with a whole album.
    @ViewBuilder
    private var playbackButtons: some View {
        Button {
            prepareFavoritesForPlayback()
        } label: {
            Group {
                if isPreparingPlayback {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "shuffle")
                        .font(.title3)
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(hasNoFavoritePlayback || isPreparingPlayback)
        .help(String(localized: "shuffle"))
        .accessibilityLabel(String(localized: "shuffle"))
    }

    private var hasNoFavoritePlayback: Bool {
        visibleAlbums.isEmpty && visibleSongs.isEmpty
    }

    /// Shuffles the favorite songs together with every track of the favorite
    /// albums. Favorite artists are left out on purpose: a single artist can add
    /// hundreds of tracks and needs its whole discography fetched first.
    private func prepareFavoritesForPlayback() {
        let albums = visibleAlbums
        let favoriteSongs = visibleSongs
        guard !albums.isEmpty || !favoriteSongs.isEmpty else { return }

        playbackTask?.cancel()
        isPreparingPlayback = true

        let useDownloadedSongs = effectiveShowDownloadsOnly
        let downloadedSongsByAlbumID = Dictionary(
            downloadStore.albums.map { album in
                (album.albumId, album.songs.map { $0.asSong() })
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let api = SubsonicAPIService.shared
        let serverID = api.activeServer?.id
        let player = appState.player

        playbackTask = Task { @MainActor in
            var collected: [Song] = []
            var seen = Set<String>()
            for song in favoriteSongs where seen.insert(song.id).inserted {
                collected.append(song)
            }
            for album in albums {
                let albumSongs: [Song]
                if useDownloadedSongs {
                    albumSongs = downloadedSongsByAlbumID[album.id] ?? []
                } else if let known = album.songs {
                    albumSongs = known
                } else {
                    albumSongs = (try? await api.getAlbum(id: album.id, retries: 1).song) ?? []
                }
                for song in albumSongs where seen.insert(song.id).inserted {
                    collected.append(song)
                }
            }

            guard !Task.isCancelled, api.activeServer?.id == serverID else {
                isPreparingPlayback = false
                return
            }

            isPreparingPlayback = false
            playbackTask = nil

            guard !collected.isEmpty else {
                NotificationCenter.default.post(
                    name: .showToast,
                    object: String(localized: "playback_failed")
                )
                return
            }

            player.playShuffled(songs: collected)
        }
    }

    private func cancelPlaybackPreparation() {
        playbackTask?.cancel()
        playbackTask = nil
        isPreparingPlayback = false
    }

    private var navigationTitle: String {
        switch scope {
        case .overview: String(localized: "favorites")
        case .albums: String(localized: "favorite_albums")
        case .songs: String(localized: "favorite_songs")
        case .artists: String(localized: "favorite_artists")
        }
    }

    private var isCurrentScopeEmpty: Bool {
        switch scope {
        case .overview: visibleAlbums.isEmpty && visibleSongs.isEmpty && visibleArtists.isEmpty
        case .albums: visibleAlbums.isEmpty
        case .songs: visibleSongs.isEmpty
        case .artists: visibleArtists.isEmpty
        }
    }

    @ViewBuilder
    private var favoritesContent: some View {
        if libraryStore.isLoadingStarred && isCurrentScopeEmpty {
            ProgressView(String(localized: "loading_favorites"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        } else if isCurrentScopeEmpty, !activeQuery.isEmpty {
            ContentUnavailableView.search(text: activeQuery)
                .padding(.vertical, 60)
        } else if isCurrentScopeEmpty {
            ContentUnavailableView(
                String(localized: "no_favorites"),
                systemImage: "heart",
                description: Text(String(localized: "mark_tracks_albums_and_artists_as_favorites"))
            )
            .padding(.vertical, 60)
        } else {
            Group {
                switch scope {
                case .overview:
                    favoritesOverview
                case .albums:
                    FavoritesSection(title: navigationTitle) {
                        albumGrid(visibleAlbums)
                    }
                case .songs:
                    FavoritesSection(title: navigationTitle) {
                        songList(visibleSongs)
                    }
                case .artists:
                    FavoritesSection(title: navigationTitle) {
                        artistGrid(visibleArtists)
                    }
                }
            }
            .padding(20)
        }
    }

    private var favoritesOverview: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !visibleSongs.isEmpty {
                FavoritesSection(title: String(localized: "tracks")) {
                    songList(Array(visibleSongs.prefix(FavoritePresentation.previewLimit)))
                    showAllLinkIfNeeded(scope: .songs, count: visibleSongs.count)
                }
            }

            if !visibleAlbums.isEmpty {
                FavoritesSection(title: String(localized: "albums")) {
                    albumGrid(Array(visibleAlbums.prefix(FavoritePresentation.previewLimit)))
                    showAllLinkIfNeeded(scope: .albums, count: visibleAlbums.count)
                }
            }

            if !visibleArtists.isEmpty {
                FavoritesSection(title: String(localized: "artists")) {
                    artistGrid(Array(visibleArtists.prefix(FavoritePresentation.previewLimit)))
                    showAllLinkIfNeeded(scope: .artists, count: visibleArtists.count)
                }
            }
        }
    }

    // Same column metrics as the albums page: the cover is 160pt wide, so a
    // narrower minimum let the grid centre it inside its column and pushed it
    // to the right of the section title.
    private func albumGrid(_ albums: [Album]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)], alignment: .leading, spacing: 20) {
            ForEach(albums) { album in
                NavigationLink(value: album) {
                    AlbumGridItem(album: album, showsFavoriteBadge: false)
                        .equatable()
                }
                .buttonStyle(.plain)
                .albumContextMenu(album)
                .environmentObject(libraryStore)
            }
        }
    }

    // Same column metrics as the artists page (portrait is 140pt wide).
    private func artistGrid(_ artists: [Artist]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)], alignment: .leading, spacing: 20) {
            ForEach(artists) { artist in
                NavigationLink(value: artist) {
                    ArtistGridItem(
                        artist: artist,
                        isDownloaded: DownloadUIStateHub.shared
                            .isArtistBadgeDownloaded(artist.name),
                        showsFavoriteBadge: false
                    )
                    .equatable()
                }
                .buttonStyle(.plain)
                .artistContextMenu(artist)
                .environmentObject(libraryStore)
            }
        }
    }

    private func songList(_ songs: [Song]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(songs) { song in
                FavoriteSongRow(
                    song: song,
                    isPlaying: appState.player.currentSong?.id == song.id,
                    showPlaylist: showPlaylistActions,
                    themeColor: themeColor
                ) {
                    let index = visibleSongs.firstIndex(where: { $0.id == song.id }) ?? 0
                    appState.player.play(songs: visibleSongs, startIndex: index)
                } onPlayNext: {
                    appState.player.addPlayNext(song)
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                } onAddToQueue: {
                    appState.player.addToQueue(song)
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                } onRemoveFavorite: {
                    Task { await libraryStore.toggleStarSong(song) }
                } onAddToPlaylist: {
                    NotificationCenter.default.post(name: .addSongsToPlaylist, object: [song.id])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, -20)
    }

    @ViewBuilder
    private func showAllLinkIfNeeded(scope: FavoritesScope, count: Int) -> some View {
        if count > FavoritePresentation.previewLimit {
            NavigationLink(value: scope) {
                Text(String(format: String(localized: "show_all_count_format"), count))
                    .foregroundStyle(themeColor)
            }
            .buttonStyle(.plain)
        }
    }
}

struct FavoritesSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
            content
        }
    }
}

struct FavoriteSongRow: View {
    let song: Song
    let isPlaying: Bool
    var showPlaylist: Bool = false
    let themeColor: Color
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onRemoveFavorite: () -> Void
    let onAddToPlaylist: () -> Void

    private var offlineMode: OfflineModeService { .shared }
    private var showInstantMixActions: Bool {
        UserDefaults.standard.object(forKey: PersonalizationPreferenceKey.showInstantMixActions) as? Bool ?? true
    }
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(
                coverArtID: song.coverArt,
                requestSize: 80,
                size: 40,
                cornerRadius: 6
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(isPlaying ? themeColor : .primary)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let album = song.album {
                Text(album)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing)
            }

            HStack(spacing: 4) {
                DownloadStatusIcon(songId: song.id)
            }

            Text(song.durationString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(height: 52)
        // 20 matches the page's outer padding, which `songList` cancels out with a
        // negative inset so the hover background spans the full width. Without it
        // the track titles sat left of the section headings and the covers.
        .padding(.horizontal, 20)
        .background {
            Color(NSColor.windowBackgroundColor)
            if isHovered {
                Color.primary.opacity(0.07)
            } else if isPlaying {
                themeColor.opacity(0.08)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onPlay() }
        .contextMenu {
            Button(String(localized: "play")) { onPlay() }
            if showInstantMixActions && !offlineMode.isOffline {
                Button(String(localized: "instant_mix")) {
                    InstantMixService.playSongMix(for: song)
                }
            }
            Divider()
            Button(String(localized: "play_next")) { onPlayNext() }
            Button(String(localized: "add_to_queue")) { onAddToQueue() }
            Divider()
            Button {
                onRemoveFavorite()
            } label: {
                Label(String(localized: "remove_from_favorites"), systemImage: "heart.slash.fill")
            }
            if showPlaylist {
                Button(String(localized: "add_to_playlist")) { onAddToPlaylist() }
            }
            Divider()
            Button(String(localized: "song_info_details")) {
                AppState.shared.showSongInfo(song)
            }
        }
    }
}
