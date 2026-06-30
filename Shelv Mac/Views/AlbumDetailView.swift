import SwiftUI
import Combine

struct AlbumDetailView: View {
    let albumId: String
    let albumName: String
    var initialCoverArtId: String? = nil
    @StateObject private var vm = AlbumDetailViewModel()
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject private var player = AudioPlayerService.shared
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage("enableDownloads") private var enableDownloads = false
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false
    @Environment(\.themeColor) private var themeColor
    @State private var showDeleteDownloadConfirm = false
    @State private var searchQuery = ""

    private var effectiveShowDownloadsOnly: Bool {
        offlineMode.isOffline || showDownloadsOnly
    }

    private var displaySongs: [Song] {
        let base = effectiveShowDownloadsOnly
            ? vm.songs.filter { downloadStore.isDownloaded(songId: $0.id) }
            : vm.songs
        guard !searchQuery.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
                || ($0.artist?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
    }

    private var instantMixAlbum: Album {
        guard let album = vm.album else {
            return Album(id: albumId, name: albumName, coverArt: initialCoverArtId, songs: vm.songs)
        }
        return Album(id: album.id,
                     name: album.name,
                     artist: album.artist,
                     artistId: album.artistId,
                     coverArt: album.coverArt,
                     songCount: album.songCount,
                     duration: album.duration,
                     year: album.year,
                     genre: album.genre,
                     starred: album.starred,
                     songs: vm.songs)
    }

    private var discGroups: [(disc: Int, songs: [Song])] {
        let discNumbers = Set(displaySongs.compactMap(\.discNumber))
        guard discNumbers.count >= 2 else { return [] }
        let sorted = displaySongs.sorted {
            let d0 = $0.discNumber ?? 1, d1 = $1.discNumber ?? 1
            if d0 != d1 { return d0 < d1 }
            return ($0.track ?? 0) < ($1.track ?? 0)
        }
        let grouped = Dictionary(grouping: sorted) { $0.discNumber ?? 1 }
        return grouped.keys.sorted().map { disc in (disc: disc, songs: grouped[disc, default: []]) }
    }

    private var useDiscGrouping: Bool {
        let discNumbers = Set(displaySongs.compactMap(\.discNumber))
        return discNumbers.count >= 2
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                headerView

                if vm.isLoading {
                    ProgressView(String(localized: "loading_tracks"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if useDiscGrouping {
                    ForEach(discGroups, id: \.disc) { group in
                        discHeaderRow(group.disc)
                        ForEach(group.songs, id: \.id) { song in
                            albumTrackRow(song: song, playIndex: displaySongs.firstIndex(where: { $0.id == song.id }) ?? 0)
                        }
                    }
                } else {
                    ForEach(Array(displaySongs.enumerated()), id: \.element.id) { index, song in
                        albumTrackRow(song: song, playIndex: index)
                    }
                }

                if let err = vm.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle(vm.album?.name ?? albumName)
        .searchable(text: $searchQuery, prompt: String(localized: "search_songs"))
        .task(id: albumId) {
            let local = downloadStore.albums.first(where: { $0.albumId == albumId })
            await vm.load(albumId: albumId, fallback: local)
        }
        .alert(String(localized: "delete_downloads_2"), isPresented: $showDeleteDownloadConfirm) {
            Button(String(localized: "delete"), role: .destructive) {
                downloadStore.deleteAlbum(albumId)
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
        .onChange(of: downloadStore.songs.count) { _, _ in
            guard offlineMode.isOffline else { return }
            let local = downloadStore.albums.first(where: { $0.albumId == albumId })
            Task { await vm.load(albumId: albumId, fallback: local) }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                CoverArtView(url: coverURL, size: 160, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.25), radius: 14)

                VStack(alignment: .leading, spacing: 8) {
                    Text(vm.album?.name ?? albumName)
                        .font(.title.bold())
                        .lineLimit(2)

                    if let artist = vm.album?.artist {
                        if let artistId = vm.album?.artistId {
                            Button {
                                appState.selectedPlaylist = nil
                                appState.selectedSidebar = .artists
                                appState.navigationPath = NavigationPath()
                                appState.navigationPath.append(Artist(id: artistId, name: artist, albumCount: nil, coverArt: nil, starred: nil))
                            } label: {
                                Text(artist)
                                    .font(.title3)
                                    .foregroundStyle(themeColor)
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "go_to_artist"))
                            .onHover { inside in
                                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                        } else {
                            Text(artist)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        if let year  = vm.album?.year     { Text(String(year)) }
                        if let genre = vm.album?.genre    { Text("·"); Text(genre) }
                        if let count = vm.album?.songCount { Text("·"); Text(String(format: String(localized: "count_tracks_format"), count)) }
                        if let dur   = vm.album?.duration  { Text("·"); Text(formatDuration(dur)) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                    Spacer(minLength: 12)

                    ViewThatFits(in: .horizontal) {
                        actionButtons(iconOnly: false)
                        actionButtons(iconOnly: true)
                    }
                }

                Spacer()
            }
            .padding(28)

            Divider()
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func actionButtons(iconOnly: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                appState.player.play(songs: displaySongs)
            } label: {
                Label(String(localized: "play"), systemImage: "play.fill")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                    .frame(minWidth: iconOnly ? nil : 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(themeColor)
            .controlSize(.large)
            .disabled(vm.isLoading || displaySongs.isEmpty)

            Button {
                appState.player.playShuffled(songs: displaySongs)
            } label: {
                Label(String(localized: "shuffle"), systemImage: "shuffle")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                    .frame(minWidth: iconOnly ? nil : 100)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(vm.isLoading || displaySongs.isEmpty)

            if showInstantMixActions && !offlineMode.isOffline {
                Button {
                    InstantMixService.playAlbumMix(for: instantMixAlbum, player: appState.player)
                } label: {
                    Label(String(localized: "instant_mix"), systemImage: "sparkles")
                        .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(vm.isLoading)
            }

            Button {
                appState.player.addPlayNext(displaySongs)
                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
            } label: {
                Label(String(localized: "play_next"), systemImage: "text.insert")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(vm.isLoading || displaySongs.isEmpty)

            Button {
                appState.player.addToQueue(displaySongs)
                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
            } label: {
                Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(vm.isLoading || displaySongs.isEmpty)

            if enableDownloads, let album = vm.album {
                downloadHeaderButton(for: album, iconOnly: iconOnly)
            }

            if showFavoriteActions && !offlineMode.isOffline, let album = vm.album {
                let albumModel = Album(id: album.id, name: album.name, artist: album.artist,
                                       artistId: album.artistId, coverArt: album.coverArt,
                                       songCount: album.songCount, duration: album.duration,
                                       year: album.year, genre: album.genre,
                                       starred: album.starred)
                let isStarred = libraryStore.isAlbumStarred(albumModel)
                Button {
                    Task { await libraryStore.toggleStarAlbum(albumModel) }
                } label: {
                    Image(systemName: isStarred ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(isStarred ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(isStarred
                      ? String(localized: "remove_from_favorites")
                      : String(localized: "add_to_favorites"))
            }
        }
    }

    @ViewBuilder
    private func discHeaderRow(_ disc: Int) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Disc \(disc)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                Spacer()
            }

            Divider()
                .padding(.horizontal, 28)
        }
    }

    @ViewBuilder
    private func albumTrackRow(song: Song, playIndex: Int) -> some View {
        TrackRow(
            song: song,
            isPlaying: player.currentSong?.id == song.id,
            showFavorite: showFavoriteActions,
            showPlaylist: showPlaylistActions,
            isStarred: libraryStore.isSongStarred(song)
        ) {
            appState.player.play(songs: displaySongs, startIndex: playIndex)
        } onPlayNext: {
            appState.player.addPlayNext(song)
            NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
        } onAddToQueue: {
            appState.player.addToQueue(song)
            NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
        } onFavorite: {
            Task { await libraryStore.toggleStarSong(song) }
        } onAddToPlaylist: {
            NotificationCenter.default.post(name: .addSongsToPlaylist, object: [song.id])
        }
    }

    private var coverURL: URL? {
        let id = vm.album?.coverArt ?? initialCoverArtId ?? albumId
        return SubsonicAPIService.shared.coverArtURL(id: id, size: 320)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return "\(m):\(String(format: "%02d", s)) min"
    }

    @ViewBuilder
    private func downloadHeaderButton(for album: AlbumDetail, iconOnly: Bool) -> some View {
        let total = vm.songs.count
        let albumModel = Album(id: album.id, name: album.name, artist: album.artist,
                               artistId: album.artistId, coverArt: album.coverArt,
                               songCount: album.songCount, duration: album.duration,
                               year: album.year, genre: album.genre,
                               starred: album.starred)
        let status = downloadStore.albumDownloadStatus(albumId: album.id, totalSongs: total)
        switch status {
        case .none:
            if !offlineMode.isOffline {
                Button {
                    downloadStore.enqueueAlbum(albumModel)
                } label: {
                    Label(String(localized: "download"), systemImage: "arrow.down.circle")
                        .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case .partial(let done, let tot):
            if !offlineMode.isOffline {
                Button {
                    downloadStore.enqueueAlbum(albumModel)
                } label: {
                    Label("Rest (\(tot - done))", systemImage: "arrow.down.circle")
                        .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Button {
                showDeleteDownloadConfirm = true
            } label: {
                Label(String(localized: "delete_downloads"), systemImage: "arrow.down.circle")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .complete:
            Button {
                showDeleteDownloadConfirm = true
            } label: {
                Label(String(localized: "delete_downloads"), systemImage: "arrow.down.circle")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        }
    }
}

struct TrackRow: View {
    let song: Song
    let isPlaying: Bool
    var showFavorite: Bool = false
    var showPlaylist: Bool = false
    var isStarred: Bool = false
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    var onFavorite: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil

    @Environment(\.themeColor) private var themeColor
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("enableDownloads") private var enableDownloads = false
    @State private var isHovered = false
    @State private var waveformPulse = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(themeColor)
                        .opacity(waveformPulse ? 1.0 : 0.3)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: waveformPulse)
                        .onAppear { waveformPulse = true }
                        .onDisappear { waveformPulse = false }
                } else {
                    Text(song.displayTrack)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .frame(width: 36, alignment: .trailing)
            .padding(.leading, 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 14)

            Spacer()

            HStack(spacing: 8) {
                DownloadStatusIcon(songId: song.id)
                Text(song.durationString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.trailing, 24)
        }
        .frame(height: 52)
        .background {
            Color(NSColor.windowBackgroundColor)
            if isHovered {
                Color.primary.opacity(0.07)
            }
        }
        .contentShape(Rectangle())
        .focusable(false)
        .onHover { isHovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { onPlay() })
        .contextMenu {
            Button(String(localized: "play")) { onPlay() }
            Divider()
            Button(String(localized: "play_next")) { onPlayNext() }
            Button(String(localized: "add_to_queue")) { onAddToQueue() }
            if showFavorite || showPlaylist {
                Divider()
                if showFavorite, let onFavorite {
                    Button(isStarred
                           ? String(localized: "remove_from_favorites")
                           : String(localized: "add_to_favorites")) {
                        onFavorite()
                    }
                }
                if showPlaylist, let onAddToPlaylist {
                    Button(String(localized: "add_to_playlist")) {
                        onAddToPlaylist()
                    }
                }
            }
        }
    }
}

@MainActor
class AlbumDetailViewModel: ObservableObject {
    @Published var album: AlbumDetail?
    @Published var songs: [Song] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let api = SubsonicAPIService.shared

    func load(albumId: String, fallback: DownloadedAlbum? = nil) async {
        isLoading = true
        errorMessage = nil
        if let fallback, OfflineModeService.shared.isOffline {
            populateFromLocal(fallback)
            isLoading = false
            return
        }
        do {
            let detail = try await api.getAlbum(id: albumId)
            album = detail
            songs = detail.song ?? []
        } catch {
            if let fallback {
                populateFromLocal(fallback)
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func populateFromLocal(_ local: DownloadedAlbum) {
        let mapped = local.songs.map { $0.asSong() }
        songs = mapped
        album = AlbumDetail(
            id: local.albumId, name: local.title,
            artist: local.artistName, artistId: local.artistId,
            coverArt: local.coverArtId,
            songCount: local.songs.count,
            duration: local.songs.reduce(0) { $0 + ($1.duration ?? 0) },
            year: nil, genre: nil, starred: nil,
            song: mapped
        )
    }
}

#Preview {
    NavigationStack {
        AlbumDetailView(albumId: "1", albumName: "Vorschau Album")
    }
    .frame(width: 700, height: 600)
    .environmentObject(AppState.shared)
    .environmentObject(LibraryViewModel())
}
