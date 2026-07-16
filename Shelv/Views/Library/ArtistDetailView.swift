import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @EnvironmentObject var serverStore: ServerStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage("enableDownloads") private var enableDownloads = true

    private func serverStableId() -> String { serverStore.activeServer?.stableId ?? "" }
    @AppStorage("artistDetailAlbumSort") private var sortRaw: String = AlbumSortOption.newest.rawValue
    @AppStorage("artistDetailAlbumDirection") private var directionRaw: String = SortDirection.descending.rawValue
    @AppStorage("artistDetailAlbumIsGrid") private var isGrid: Bool = true

    @State private var detail: ArtistDetail?
    @State private var biography: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var currentToast: ShelveToast?
    @State private var searchQuery = ""
    @State private var albumToDeleteDownloads: Album?
    @State private var showDeleteArtistDownloadConfirm = false
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    private var sortOption: AlbumSortOption {
        AlbumSortOption(rawValue: sortRaw) ?? .newest
    }

    private var direction: SortDirection {
        SortDirection(rawValue: directionRaw) ?? .descending
    }

    private var filteredAlbums: [Album] {
        guard !searchQuery.isEmpty else { return sortedAlbums }
        return sortedAlbums.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    private var sortedAlbums: [Album] {
        ArtistAlbumPlaybackOrder.sorted(
            detail?.album ?? [],
            preference: ArtistAlbumSortPreference(
                sortRaw: sortRaw,
                directionRaw: directionRaw
            )
        )
    }

    var body: some View {
        Group {
            if isGrid {
                gridBody
            } else {
                listBody
            }
        }
        .searchable(text: $searchQuery, prompt: String(localized: "search_albums"))
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showFavoriteActions && !offlineMode.isOffline {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await libraryStore.toggleStarArtist(artist) }
                    } label: {
                        Image(systemName: libraryStore.isArtistStarred(artist) ? "heart.fill" : "heart")
                            .foregroundStyle(libraryStore.isArtistStarred(artist) ? accentColor : .secondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                artistMenu
            }
        }
        .shelveToast($currentToast)
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
        .alert(
            String(localized: "delete_downloads"),
            isPresented: $showDeleteArtistDownloadConfirm
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                for album in sortedAlbums {
                    downloadStore.deleteAlbum(album.id)
                }
                currentToast = ShelveToast(message: String(localized: "downloads_deleted"))
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
        .onChange(of: offlineMode.isOffline) { _, isOffline in
            if isOffline && sortOption.requiresServer {
                sortRaw = AlbumSortOption.alphabetical.rawValue
            }
            Task { await loadDetail() }
        }
        .onChange(of: downloadStore.songs.count) { _, _ in
            guard offlineMode.isOffline else { return }
            populateFromLocal()
        }
        .task {
            guard detail == nil else { return }
            await loadDetail()
        }
    }

    private var artistHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                AlbumArtView(coverArtId: artist.coverArt, size: 300, isCircle: true)
                    .frame(width: 100, height: 100)
                VStack(alignment: .leading, spacing: 8) {
                    Text(artist.name)
                        .font(.title2).bold()
                    if let count = detail?.albumCount ?? artist.albumCount {
                        Text("\(count) \(String(localized: "albums"))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        Button {
                            let albums = sortedAlbums
                            guard !albums.isEmpty else { return }
                            Task {
                                let songs = await fetchAllSongs(from: albums)
                                guard !songs.isEmpty else { return }
                                player.play(songs: songs, startIndex: 0)
                            }
                        } label: {
                            Label(String(localized: "play"), systemImage: "play.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.body).bold()
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)

                        Button {
                            let albums = sortedAlbums
                            guard !albums.isEmpty else { return }
                            Task {
                                let songs = await fetchAllSongs(from: albums)
                                guard !songs.isEmpty else { return }
                                player.playShuffled(songs: songs)
                            }
                        } label: {
                            Label(String(localized: "shuffle"), systemImage: "shuffle")
                                .labelStyle(.titleAndIcon)
                                .font(.body).bold()
                                .foregroundStyle(accentColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                    }
                }
            }

            if enableDownloads, !isLoading, !sortedAlbums.isEmpty {
                downloadHeaderButtons()
            }
        }
        .padding(.horizontal)
        .padding(.top, 16)
    }

    private var gridBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                artistHeader

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let msg = errorMessage {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                } else if !sortedAlbums.isEmpty {
                    Text(String(localized: "albums"))
                        .font(.title3).bold()
                        .padding(.horizontal)

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filteredAlbums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCardView(album: album, showArtist: false, showYear: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }

                if let bio = biography, !bio.isEmpty {
                    ArtistBiographyBox(biography: bio, accentColor: accentColor)
                        .padding(.horizontal)
                }

                PlayerBottomSpacer()
            }
        }
        .scrollIndicators(.hidden)
    }

    private var listBody: some View {
        List {
            Section {
                artistHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if let msg = errorMessage {
                Section {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if !sortedAlbums.isEmpty {
                Section {
                    ForEach(filteredAlbums) { album in
                        NavigationLink(destination: AlbumDetailView(album: album)) {
                            albumListRow(album)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .albumContextMenu(album, showPreview: false)
                        .personalizedAlbumArtistSwipeActions(
                            isOffline: offlineMode.isOffline,
                            isFavorite: libraryStore.isAlbumStarred(album),
                            downloadState: albumDownloadState(album),
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
                } header: {
                    HStack {
                        Text(String(localized: "albums"))
                            .font(.title3).bold()
                            .textCase(nil)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.leading, 0)
                }
            }

            if let bio = biography, !bio.isEmpty {
                Section {
                    ArtistBiographyBox(biography: bio, accentColor: accentColor)
                        .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
    }

    private func songsForAlbum(_ album: Album) async -> [Song] {
        if offlineMode.isOffline {
            return downloadStore.albums.first { $0.albumId == album.id }?.songs.map { $0.asSong() } ?? []
        }
        guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id) else { return [] }
        return detail.song ?? []
    }

    private func queueAlbum(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            await MainActor.run {
                player.addToQueue(songs)
                currentToast = ShelveToast(message: String(localized: "added_to_queue"))
            }
        }
    }

    private func playNextAlbum(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            await MainActor.run {
                player.addPlayNext(songs)
                currentToast = ShelveToast(message: String(localized: "plays_next"))
            }
        }
    }

    private func addAlbumToPlaylist(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            await MainActor.run {
                NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
            }
        }
    }

    private func albumDownloadState(_ album: Album) -> PersonalizedDownloadSwipeState {
        guard enableDownloads else { return .hidden }
        let status = downloadStore.albumDownloadStatus(albumId: album.id, totalSongs: album.songCount ?? 0)
        switch status {
        case .none, .partial:
            return offlineMode.isOffline ? .hidden : .download
        case .complete:
            return .delete
        }
    }

    private func handleAlbumDownloadSwipe(_ album: Album) {
        guard enableDownloads else { return }
        let status = downloadStore.albumDownloadStatus(albumId: album.id, totalSongs: album.songCount ?? 0)
        switch status {
        case .none, .partial:
            guard !offlineMode.isOffline else { return }
            haptic(); downloadStore.enqueueAlbum(album)
        case .complete:
            haptic(); albumToDeleteDownloads = album
        }
    }

    @ViewBuilder
    private func albumListRow(_ album: Album) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: album.coverArt, size: 120, cornerRadius: 8)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let year = album.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            AlbumDownloadBadge(albumId: album.id)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var artistMenu: some View {
        Menu {
            if showInstantMixActions && !offlineMode.isOffline {
                Button {
                    playInstantMix()
                } label: {
                    Label(String(localized: "instant_mix"), systemImage: "sparkles")
                }

                Divider()
            }

            Button {
                let albums = sortedAlbums
                guard !albums.isEmpty else { return }
                Task {
                    let songs = await fetchAllSongs(from: albums)
                    guard !songs.isEmpty else { return }
                    player.addPlayNext(songs)
                    currentToast = ShelveToast(message: String(localized: "plays_next"))
                }
            } label: {
                Label(String(localized: "play_next"), systemImage: "text.insert")
            }
            .disabled(isLoading)

            Button {
                let albums = sortedAlbums
                guard !albums.isEmpty else { return }
                Task {
                    let songs = await fetchAllSongs(from: albums)
                    guard !songs.isEmpty else { return }
                    player.addToQueue(songs)
                    currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                }
            } label: {
                Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
            }
            .disabled(isLoading)

            if showPlaylistActions && !offlineMode.isOffline {
                Button {
                    let albums = sortedAlbums
                    guard !albums.isEmpty else { return }
                    Task {
                        let songs = await fetchAllSongs(from: albums)
                        guard !songs.isEmpty else { return }
                        NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                    }
                } label: {
                    Label(String(localized: "add_to_playlist"), systemImage: "music.note.list")
                }
                .disabled(isLoading)
            }

            Divider()

            Button { isGrid.toggle() } label: {
                Label(
                    isGrid ? String(localized: "list_view") : String(localized: "grid_view"),
                    systemImage: isGrid ? "list.bullet" : "square.grid.2x2"
                )
            }

            Divider()

            Menu {
                Picker(selection: $sortRaw) {
                    ForEach(AlbumSortOption.allCases.filter {
                        $0 != .artist && (!offlineMode.isOffline || !$0.requiresServer)
                    }, id: \.rawValue) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)

                if sortOption != .alphabetical {
                    Picker(selection: $directionRaw) {
                        ForEach(SortDirection.allCases, id: \.rawValue) { dir in
                            Text(dir.label).tag(dir.rawValue)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.inline)
                }
            } label: {
                Label(String(localized: "sort"), systemImage: "arrow.up.arrow.down")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(accentColor)
        }
    }

    private func playInstantMix() {
        InstantMixService.playArtistMix(for: artist, player: player)
    }

    private func loadDetail() async {
        isLoading = true
        if offlineMode.isOffline {
            populateFromLocal()
            isLoading = false
            return
        }
        do {
            async let artistDetail = SubsonicAPIService.shared.getArtist(id: artist.id)
            async let artistInfo = SubsonicAPIService.shared.getArtistInfo(id: artist.id)
            detail = try await artistDetail
            biography = (try? await artistInfo)?.biography?.strippingHTML
        } catch {
            populateFromLocal()
            if detail == nil {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func populateFromLocal() {
        guard let local = downloadStore.artists.first(where: { $0.name == artist.name }) else { return }
        let albumsAsModel = local.albums.map { $0.asAlbum() }
        detail = ArtistDetail(
            id: local.artistId,
            name: local.name,
            albumCount: albumsAsModel.count,
            coverArt: local.coverArtId,
            album: albumsAsModel
        )
    }

    private func fetchAllSongs(from albums: [Album]) async -> [Song] {
        if offlineMode.isOffline {
            return albums.compactMap(\.songs).flatMap { $0 }
        }
        return await PlaybackContentResolver.artistSongs(from: albums) { albumID in
            (try? await SubsonicAPIService.shared.getAlbum(id: albumID).song) ?? []
        }
    }

    private var artistDownloadStatus: AlbumDownloadStatus {
        let albums = sortedAlbums
        guard !albums.isEmpty else { return .none }
        var totalSongs = 0
        var downloadedSongs = 0
        for album in albums {
            let count = album.songCount ?? 0
            let status = downloadStore.albumDownloadStatus(albumId: album.id, totalSongs: count)
            totalSongs += count
            switch status {
            case .none: break
            case .partial(let done, _): downloadedSongs += done
            case .complete: downloadedSongs += count
            }
        }
        guard totalSongs > 0 else { return .none }
        if downloadedSongs == 0 { return .none }
        if downloadedSongs >= totalSongs { return .complete }
        return .partial(downloaded: downloadedSongs, total: totalSongs)
    }

    @ViewBuilder
    private func downloadHeaderButtons() -> some View {
        HStack(spacing: 10) {
            switch artistDownloadStatus {
            case .none:
                if !offlineMode.isOffline {
                    Button {
                        haptic()
                        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: serverStableId()) }
                        currentToast = ShelveToast(message: String(localized: "download_started"))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text(String(localized: "download"))
                        }
                        .font(.subheadline).bold()
                        .foregroundStyle(accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(accentColor.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            case .partial(let done, let tot):
                if !offlineMode.isOffline {
                    Button {
                        haptic()
                        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: serverStableId()) }
                        currentToast = ShelveToast(message: String(localized: "download_started"))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text("Rest (\(tot - done))")
                        }
                        .font(.subheadline).bold()
                        .foregroundStyle(accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(accentColor.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    haptic(); showDeleteArtistDownloadConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text(String(localized: "delete_downloads_2"))
                    }
                    .font(.subheadline).bold()
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            case .complete:
                Button {
                    haptic(); showDeleteArtistDownloadConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text(String(localized: "delete_downloads_2"))
                    }
                    .font(.subheadline).bold()
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ArtistBiographyBox: View {
    let biography: String
    let accentColor: Color
    @State private var expanded = false

    private var isLong: Bool { biography.count > 280 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(biography)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .animation(.easeInOut(duration: 0.2), value: expanded)

            if isLong {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded
                         ? String(localized: "artist_bio_show_less")
                         : String(localized: "artist_bio_show_more"))
                        .font(.subheadline).bold()
                        .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension String {
    var strippingHTML: String {
        self.replacing(/<[^>]+>/, with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
