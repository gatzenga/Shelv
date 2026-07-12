import SwiftUI

struct DownloadsView: View {
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var libraryStore = LibraryStore.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("downloadsSegment") private var segmentRaw: String = "albums"
    @AppStorage("downloadsAlbumIsGrid") private var albumIsGrid: Bool = true

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @State private var albumToDeleteDownloads: DownloadedAlbum?
    @State private var artistToDeleteDownloads: DownloadedArtist?

    enum Segment: String, CaseIterable {
        case albums, artists, favorites
        var label: String {
            switch self {
            case .albums:    return String(localized: "albums")
            case .artists:   return String(localized: "artists")
            case .favorites: return String(localized: "favorites")
            }
        }
    }

    private var segment: Segment {
        Segment(rawValue: segmentRaw) ?? .albums
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segmentRaw) {
                    Text(Segment.albums.label).tag(Segment.albums.rawValue)
                    Text(Segment.artists.label).tag(Segment.artists.rawValue)
                    if enableFavorites {
                        Text(Segment.favorites.label).tag(Segment.favorites.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                switch segment {
                case .albums:    albumsList
                case .artists:   artistsList
                case .favorites: favoritesList
                }
            }
            .navigationTitle(offlineMode.isOffline ? String(localized: "offline") : String(localized: "downloads"))
            .navigationBarTitleDisplayMode(.inline)
            .task { await downloadStore.reload() }
            .alert(
                String(localized: "delete_downloads"),
                isPresented: Binding(get: { albumToDeleteDownloads != nil }, set: { if !$0 { albumToDeleteDownloads = nil } }),
                presenting: albumToDeleteDownloads
            ) { album in
                Button(String(localized: "delete"), role: .destructive) {
                    downloadStore.deleteAlbum(album.albumId)
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
            }
            .alert(
                String(localized: "delete_downloads"),
                isPresented: Binding(get: { artistToDeleteDownloads != nil }, set: { if !$0 { artistToDeleteDownloads = nil } }),
                presenting: artistToDeleteDownloads
            ) { artist in
                Button(String(localized: "delete"), role: .destructive) {
                    downloadStore.deleteArtist(artist.artistId)
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
            }
        }
    }

    @ViewBuilder
    private var albumsList: some View {
        if downloadStore.albums.isEmpty {
            emptyState(title: String(localized: "no_downloaded_albums"),
                       icon: "square.grid.2x2")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { albumIsGrid.toggle() } label: {
                        Image(systemName: albumIsGrid ? "list.bullet" : "square.grid.2x2")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
                if albumIsGrid {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 14)], spacing: 18) {
                            ForEach(downloadStore.albums) { album in
                                NavigationLink(value: album) {
                                    downloadedAlbumGridCell(album)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        haptic(); albumToDeleteDownloads = album
                                    } label: { Label(String(localized: "delete_downloads_2"), systemImage: "trash") }
                                }
                            }
                        }
                        .padding(16)
                        PlayerBottomSpacer()
                    }
                    .scrollIndicators(.hidden)
                } else {
                    List {
                        ForEach(downloadStore.albums) { album in
                            NavigationLink(value: album) {
                                DownloadedAlbumRow(album: album)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    haptic(); albumToDeleteDownloads = album
                                } label: {
                                    DeleteDownloadIcon()
                                }
                                .tint(.red)
                            }
                        }
                        PlayerBottomSpacer()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationDestination(for: DownloadedAlbum.self) { album in
                DownloadedAlbumDetailView(album: album)
            }
        }
    }

    private func downloadedAlbumGridCell(_ album: DownloadedAlbum) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtView(coverArtId: album.coverArtId, size: 300, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
            Text(album.title).font(.caption).bold().lineLimit(1)
            Text(album.artistName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder
    private var artistsList: some View {
        if downloadStore.artists.isEmpty {
            emptyState(title: String(localized: "no_downloaded_artists"),
                       icon: "music.mic")
        } else {
            List {
                ForEach(downloadStore.artists) { artist in
                    NavigationLink(value: artist) {
                        DownloadedArtistRow(artist: artist)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            haptic(); artistToDeleteDownloads = artist
                        } label: {
                            DeleteDownloadIcon()
                        }
                        .tint(.red)
                    }
                }
                PlayerBottomSpacer()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationDestination(for: DownloadedArtist.self) { artist in
                DownloadedArtistDetailView(artist: artist)
            }
            .navigationDestination(for: DownloadedAlbum.self) { album in
                DownloadedAlbumDetailView(album: album)
            }
        }
    }

    @ViewBuilder
    private var favoritesList: some View {
        // Cross-Filter: Library-Favoriten gegen Downloads
        let downloadedAlbumIds = Set(downloadStore.albums.map { $0.albumId })
        let downloadedArtistNames = Set(downloadStore.artists.map { $0.name })
        let favAlbums = libraryStore.starredAlbums.filter { downloadedAlbumIds.contains($0.id) }
        let favArtists = libraryStore.starredArtists.filter { downloadedArtistNames.contains($0.name) }
        let favSongs = downloadStore.favoriteSongs

        if favAlbums.isEmpty && favArtists.isEmpty && favSongs.isEmpty {
            emptyState(title: String(localized: "no_favorites_downloaded"),
                       icon: "heart")
        } else {
            List {
                if !favArtists.isEmpty {
                    Section(String(localized: "artists")) {
                        ForEach(favArtists) { artist in
                            if let downloaded = downloadStore.artists.first(where: { $0.name == artist.name }) {
                                NavigationLink(value: downloaded) {
                                    DownloadedArtistRow(artist: downloaded)
                                }
                            }
                        }
                    }
                }
                if !favAlbums.isEmpty {
                    Section(String(localized: "albums")) {
                        ForEach(favAlbums) { album in
                            if let downloaded = downloadStore.albums.first(where: { $0.albumId == album.id }) {
                                NavigationLink(value: downloaded) {
                                    DownloadedAlbumRow(album: downloaded)
                                }
                            }
                        }
                    }
                }
                if !favSongs.isEmpty {
                    Section(String(localized: "songs")) {
                        ForEach(favSongs) { song in
                            DownloadedSongRow(song: song, playbackList: favSongs)
                        }
                    }
                }
                PlayerBottomSpacer()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationDestination(for: DownloadedArtist.self) { artist in
                DownloadedArtistDetailView(artist: artist)
            }
            .navigationDestination(for: DownloadedAlbum.self) { album in
                DownloadedAlbumDetailView(album: album)
            }
        }
    }

    @ViewBuilder
    private func emptyState(title: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Album Row

private struct DownloadedAlbumRow: View {
    let album: DownloadedAlbum

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: album.coverArtId, size: 120, cornerRadius: 8)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.body).lineLimit(1)
                Text(album.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(album.songCount) · \(ByteCountFormatter.string(fromByteCount: album.totalBytes, countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct DownloadedArtistRow: View {
    let artist: DownloadedArtist

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: artist.coverArtId, size: 120, cornerRadius: 26, isCircle: true)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name).font(.body).lineLimit(1)
                Text("\(artist.albumCount) \(String(localized: "albums"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Album Detail

struct DownloadedAlbumDetailView: View {
    let album: DownloadedAlbum
    @ObservedObject var downloadStore = DownloadStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private let player = AudioPlayerService.shared

    @State private var currentToast: ShelveToast?

    private var currentAlbum: DownloadedAlbum? {
        downloadStore.albums.first(where: { $0.albumId == album.albumId })
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    AlbumArtView(coverArtId: album.coverArtId, size: 600, cornerRadius: 16)
                        .frame(width: 240, height: 240)
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                    Text(album.title).font(.title3).bold()
                    Text(album.artistName).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button {
                            let songs = (currentAlbum?.songs ?? album.songs).map { $0.asSong() }
                            player.play(songs: songs, startIndex: 0)
                        } label: {
                            Label(String(localized: "play"), systemImage: "play.fill")
                                .font(.body).bold().foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(accentColor)
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                        Button {
                            let songs = (currentAlbum?.songs ?? album.songs).map { $0.asSong() }
                            player.playShuffled(songs: songs)
                        } label: {
                            Label(String(localized: "shuffle"), systemImage: "shuffle")
                                .font(.body).bold().foregroundStyle(accentColor)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                let songs = currentAlbum?.songs ?? album.songs
                ForEach(Array(songs.enumerated()), id: \.element.songId) { index, song in
                    DownloadedSongRow(song: song, playbackList: songs, startIndex: index)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                haptic(); downloadStore.deleteSong(song.songId)
                            } label: {
                                DeleteDownloadIcon()
                            }
                            .tint(.red)
                        }
                }
            }

            Section {
                PlayerBottomSpacer()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .shelveToast($currentToast)
        .onChange(of: downloadStore.albums.contains(where: { $0.albumId == album.albumId })) { _, exists in
            if !exists { dismiss() }
        }
    }
}

struct DownloadedArtistDetailView: View {
    let artist: DownloadedArtist
    @ObservedObject var downloadStore = DownloadStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var albumToDeleteDownloads: DownloadedAlbum?

    private var currentArtist: DownloadedArtist? {
        downloadStore.artists.first(where: { $0.artistId == artist.artistId })
    }

    var body: some View {
        List {
            ForEach(currentArtist?.albums ?? []) { album in
                NavigationLink(value: album) {
                    DownloadedAlbumRow(album: album)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        haptic(); albumToDeleteDownloads = album
                    } label: {
                        DeleteDownloadIcon()
                    }
                    .tint(.red)
                }
            }
            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: downloadStore.artists.contains(where: { $0.artistId == artist.artistId })) { _, exists in
            if !exists { dismiss() }
        }
        .alert(
            String(localized: "delete_downloads"),
            isPresented: Binding(get: { albumToDeleteDownloads != nil }, set: { if !$0 { albumToDeleteDownloads = nil } }),
            presenting: albumToDeleteDownloads
        ) { album in
            Button(String(localized: "delete"), role: .destructive) {
                downloadStore.deleteAlbum(album.albumId)
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
    }
}

// MARK: - Song Row

struct DownloadedSongRow: View {
    let song: DownloadedSong
    let playbackList: [DownloadedSong]
    var startIndex: Int? = nil

    @ObservedObject private var offlineMode = OfflineModeService.shared
    @ObservedObject private var libraryStore = LibraryStore.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private let player = AudioPlayerService.shared
    @State private var songInfoSong: Song?
    @State private var showAddToPlaylist = false

    var body: some View {
        Button {
            play()
        } label: {
            HStack(spacing: 12) {
                AlbumArtView(coverArtId: song.coverArtId, size: 100, cornerRadius: 6)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.body).lineLimit(1)
                    Text("\(song.artistName) · \(song.albumTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let duration = song.duration {
                    Text(formatDuration(duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                play()
            } label: {
                Label(String(localized: "play"), systemImage: "play.fill")
            }

            if !offlineMode.isOffline && showInstantMixActions {
                Button {
                    InstantMixService.playSongMix(for: song.asSong())
                } label: {
                    Label(String(localized: "instant_mix"), systemImage: "sparkles")
                }
            }

            Divider()

            Button {
                player.addPlayNext(song.asSong())
            } label: {
                Label(String(localized: "play_next"), systemImage: "text.insert")
            }

            Button {
                player.addToQueue(song.asSong())
            } label: {
                Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
            }

            if !offlineMode.isOffline && (showFavoriteActions || showPlaylistActions) {
                Divider()

                if showFavoriteActions {
                    Button {
                        Task { await libraryStore.toggleStarSong(song.asSong()) }
                    } label: {
                        Label(
                            libraryStore.starredSongs.contains(where: { $0.id == song.songId })
                                ? String(localized: "unfavorite")
                                : String(localized: "favorite"),
                            systemImage: libraryStore.starredSongs.contains(where: { $0.id == song.songId })
                                ? "heart.slash"
                                : "heart"
                        )
                    }
                }

                if showPlaylistActions {
                    Button {
                        showAddToPlaylist = true
                    } label: {
                        Label(String(localized: "add_to_playlist"), systemImage: "music.note.list")
                    }
                }
            }

            Divider()

            Button {
                songInfoSong = song.asSong()
            } label: {
                Label(String(localized: "song_info_details"), systemImage: "info.circle")
            }
        }
        .sheet(item: $songInfoSong) { song in
            SongInfoSheetView(song: song, initialTab: .details)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(songIds: [song.songId])
        }
    }

    private func play() {
        let songs = playbackList.map { $0.asSong() }
        let idx = startIndex ?? playbackList.firstIndex(where: { $0.songId == song.songId }) ?? 0
        player.play(songs: songs, startIndex: idx)
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
