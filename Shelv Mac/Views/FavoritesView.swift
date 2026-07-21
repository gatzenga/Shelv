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
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false
    @Environment(\.themeColor) private var themeColor
    private let scope: FavoritesScope

    init() {
        scope = .overview
    }

    init(scope: FavoritesScope) {
        self.scope = scope
    }

    private var effectiveShowDownloadsOnly: Bool {
        offlineMode.isOffline || showDownloadsOnly
    }

    private var visibleArtists: [Artist] {
        guard effectiveShowDownloadsOnly else { return libraryStore.starredArtists }
        let downloadedNames = Set(downloadStore.artists.map(\.name))
        return libraryStore.starredArtists.filter { downloadedNames.contains($0.name) }
    }

    private var visibleAlbums: [Album] {
        guard effectiveShowDownloadsOnly else { return libraryStore.starredAlbums }
        let downloadedIds = Set(downloadStore.albums.map(\.albumId))
        return libraryStore.starredAlbums.filter { downloadedIds.contains($0.id) }
    }

    private var visibleSongs: [Song] {
        guard effectiveShowDownloadsOnly else { return libraryStore.starredSongs }
        return libraryStore.starredSongs.filter { downloadStore.isDownloaded(songId: $0.id) }
    }

    var body: some View {
        ScrollView {
            favoritesContent
        }
        .navigationTitle(navigationTitle)
        .task { await libraryStore.loadStarred() }
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
            if !visibleAlbums.isEmpty {
                FavoritesSection(title: String(localized: "albums")) {
                    albumGrid(Array(visibleAlbums.prefix(FavoritePresentation.previewLimit)))
                    showAllLinkIfNeeded(scope: .albums, count: visibleAlbums.count)
                }
            }

            if !visibleSongs.isEmpty {
                FavoritesSection(title: String(localized: "tracks")) {
                    songList(Array(visibleSongs.prefix(FavoritePresentation.previewLimit)))
                    showAllLinkIfNeeded(scope: .songs, count: visibleSongs.count)
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

    private func albumGrid(_ albums: [Album]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)], spacing: 20) {
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

    private func artistGrid(_ artists: [Artist]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16)], spacing: 20) {
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
        .padding(.horizontal, 12)
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
        .gesture(TapGesture(count: 2).onEnded { onPlay() })
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
