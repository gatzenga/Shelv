import SwiftUI

struct FavoritesView: View {
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @EnvironmentObject var appState: AppState
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false
    @Environment(\.themeColor) private var themeColor

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
            if libraryStore.isLoadingStarred
                && visibleArtists.isEmpty
                && visibleAlbums.isEmpty
                && visibleSongs.isEmpty {
                ProgressView(String(localized: "loading_favorites"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
            } else if visibleArtists.isEmpty
                        && visibleAlbums.isEmpty
                        && visibleSongs.isEmpty {
                ContentUnavailableView(
                    String(localized: "no_favorites"),
                    systemImage: "heart",
                    description: Text(String(localized: "mark_tracks_albums_and_artists_as_favorites"))
                )
                .padding(.vertical, 60)
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    if !visibleArtists.isEmpty {
                        FavoritesSection(title: String(localized: "artists")) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16)], spacing: 20) {
                                ForEach(visibleArtists) { artist in
                                    NavigationLink(value: artist) {
                                        ArtistGridItem(artist: artist)
                                    }
                                    .buttonStyle(.plain)
                                    .artistContextMenu(artist)
                                    .environmentObject(libraryStore)
                                }
                            }
                        }
                    }

                    if !visibleAlbums.isEmpty {
                        FavoritesSection(title: String(localized: "albums")) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)], spacing: 20) {
                                ForEach(visibleAlbums) { album in
                                    NavigationLink(value: album) {
                                        AlbumGridItem(album: album)
                                    }
                                    .buttonStyle(.plain)
                                    .albumContextMenu(album)
                                    .environmentObject(libraryStore)
                                }
                            }
                        }
                    }

                    if !visibleSongs.isEmpty {
                        FavoritesSection(title: String(localized: "tracks")) {
                            VStack(spacing: 0) {
                                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                                    FavoriteSongRow(
                                        song: song,
                                        isPlaying: appState.player.currentSong?.id == song.id,
                                        showPlaylist: showPlaylistActions,
                                        themeColor: themeColor
                                    ) {
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
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(String(localized: "favorites"))
        .task { await libraryStore.loadStarred() }
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

    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @EnvironmentObject private var appState: AppState
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage("enableDownloads") private var enableDownloads = true
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(
                url: song.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 80) },
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

            DownloadStatusIcon(songId: song.id)

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
            Button(String(localized: "remove_from_favorites")) { onRemoveFavorite() }
            if showPlaylist {
                Button(String(localized: "add_to_playlist")) { onAddToPlaylist() }
            }
            Divider()
            Button(String(localized: "song_info_details")) {
                appState.showSongInfo(song)
            }
        }
    }
}
