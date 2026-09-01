import SwiftUI
import Combine

struct ArtistDetailView: View {
    let artistId: String
    let artistName: String
    @StateObject private var vm = ArtistDetailViewModel()
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @ObservedObject private var musicLibraries = MusicLibraryStore.shared
    @ObservedObject private var personalizationVisibility = MacPersonalizationVisibilityStore.shared
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage("enableDownloads") private var enableDownloads = true
    @AppStorage("artistDetailAlbumSort") private var sortRaw: String = LibrarySortOption.recentlyAdded.rawValue
    @AppStorage("artistDetailAlbumDirection") private var directionRaw: String = SortDirection.descending.rawValue
    @AppStorage("artistDetailAlbumIsGrid") private var isGrid: Bool = true

    private var showFavoriteActions: Bool {
        personalizationVisibility.showFavoriteActions
    }
    private var showPlaylistActions: Bool {
        personalizationVisibility.showPlaylistActions
    }
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false
    @Environment(\.themeColor) private var themeColor
    @State private var showDeleteDownloadConfirm = false
    @State private var searchQuery = ""
    @State private var shareURL: URL?
    @State private var shareErrorMessage: String?
    @State private var artistSongs: [Song]?
    @State private var releaseGroup: ArtistReleaseGroup = .all
    @State private var isLoadingSearchSongs = false
    @State private var loadedSongSearchSourceID: String?
    @State private var topSongsFirstVisible = 0
    @State private var isShowingArtwork = false

    private var effectiveShowDownloadsOnly: Bool {
        offlineMode.isOffline || showDownloadsOnly
    }

    private var sortOption: LibrarySortOption {
        LibrarySortOption(rawValue: sortRaw) ?? .recentlyAdded
    }

    private var direction: SortDirection {
        SortDirection(rawValue: directionRaw) ?? .descending
    }

    private var availableAlbums: [Album] {
        if effectiveShowDownloadsOnly {
            let downloadedIds = Set(downloadStore.albums.map { $0.albumId })
            return vm.albums.filter { downloadedIds.contains($0.id) }
        }
        return vm.albums
    }

    private var displayAlbums: [Album] {
        let searched = searchQuery.isEmpty
            ? availableAlbums
            : availableAlbums.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        let filtered = searchQuery.isEmpty
            ? ArtistDiscography.filter(searched, to: releaseGroup)
            : searched
        return ArtistAlbumPlaybackOrder.sorted(
            filtered,
            preference: ArtistAlbumSortPreference(
                sortRaw: sortRaw,
                directionRaw: directionRaw
            )
        )
    }

    private var releaseGroups: [ArtistReleaseGroup] {
        searchQuery.isEmpty ? ArtistDiscography.availableGroups(for: availableAlbums) : []
    }

    /// Albums and short releases on their own shelves, or one shelf for the
    /// whole discography when splitting would say nothing about it.
    private var shelves: [(group: ArtistReleaseGroup, albums: [Album])] {
        ArtistDiscography.shelfGroups(for: displayAlbums).compactMap { group in
            let albums = ArtistDiscography.filter(displayAlbums, to: group)
            return albums.isEmpty ? nil : (group, albums)
        }
    }

    private var latestRelease: Album? {
        availableAlbums.max {
            ($0.year ?? 0, $0.created ?? .distantPast) < ($1.year ?? 0, $1.created ?? .distantPast)
        }
    }

    /// Releases and plays, from data the page already has. A discography holds
    /// albums, singles and EPs, so it counts releases.
    private var artistSubtitle: String? {
        let albums = vm.albums
        let count = vm.artist?.albumCount ?? albums.count
        var parts: [String] = []
        if count > 0 {
            parts.append(String(format: String(localized: "artist_release_count_format"), count))
        }
        let plays = albums.reduce(0) { $0 + ($1.playCount ?? 0) }
        if plays > 0 {
            parts.append(String(format: String(localized: "artist_play_count_format"), plays))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var lastFmURL: URL? {
        vm.lastFmURLString.flatMap(URL.init(string:))
    }

    private var musicBrainzURL: URL? {
        guard let id = vm.musicBrainzId, !id.isEmpty else { return nil }
        return URL(string: "https://musicbrainz.org/artist/\(id)")
    }

    private var filteredSongs: [Song] {
        guard !searchQuery.isEmpty else { return [] }
        return (artistSongs ?? []).filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
                || ($0.album?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
    }

    private var songSearchSourceID: String {
        [
            offlineMode.isOffline ? "offline" : "online",
            String(downloadStore.songs.count),
            availableAlbums.map(\.id).joined(separator: ",")
        ].joined(separator: "|")
    }

    private var songSearchLoadID: String {
        "\(searchQuery.isEmpty ? "idle" : "searching")|\(songSearchSourceID)"
    }

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView(String(localized: "loading_albums"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .top, spacing: 24) {
                            Button {
                                isShowingArtwork = true
                            } label: {
                                CoverArtView(url: coverURL, size: 120, isCircle: true)
                                    .shadow(color: .black.opacity(0.2), radius: 10)
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.artist?.coverArt == nil)
                            .help(String(localized: "artwork_open"))
                            .accessibilityLabel(String(localized: "artwork_open"))
                            .sheet(isPresented: $isShowingArtwork) {
                                ArtworkViewerView(
                                    coverArtId: vm.artist?.coverArt,
                                    title: vm.artist?.name ?? artistName
                                )
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text(vm.artist?.name ?? artistName)
                                    .font(.title.bold())
                                if let subtitle = artistSubtitle {
                                    Text(subtitle)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)

                                ViewThatFits(in: .horizontal) {
                                    actionButtons(iconOnly: false, compact: false)
                                    actionButtons(iconOnly: true, compact: false)
                                    actionButtons(iconOnly: true, compact: true)
                                }
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)

                        if searchQuery.isEmpty && !vm.topSongs.isEmpty {
                            topSongsSection
                        }

                        if !vm.albums.isEmpty {
                            if searchQuery.isEmpty {
                                HStack(spacing: 12) {
                                    Text(String(localized: "discography"))
                                        .font(.title3.bold())
                                    if !releaseGroups.isEmpty {
                                        Picker(String(localized: "discography"), selection: $releaseGroup) {
                                            ForEach(releaseGroups, id: \.rawValue) { group in
                                                Text(group.label).tag(group)
                                            }
                                        }
                                        .pickerStyle(.segmented)
                                        .labelsHidden()
                                        .fixedSize()
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 20)

                                if isGrid, let latestRelease {
                                    // The card pads itself (24pt), so none here.
                                    ArtistLatestReleaseCard(album: latestRelease, accentColor: themeColor)
                                }

                                HStack(spacing: 8) {
                                    Picker(String(localized: "sort"), selection: $sortRaw) {
                                        ForEach(LibrarySortOption.allCases.filter {
                                            $0 != .artist && (!offlineMode.isOffline || !$0.requiresServer)
                                        }, id: \.self) { opt in
                                            Text(opt.label).tag(opt.rawValue)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 180)
                                    if sortOption != .name {
                                        Button {
                                            directionRaw = direction == .ascending
                                                ? SortDirection.descending.rawValue
                                                : SortDirection.ascending.rawValue
                                        } label: {
                                            Image(systemName: direction == .ascending ? "arrow.up" : "arrow.down")
                                                .font(.title3)
                                        }
                                        .buttonStyle(.borderless)
                                        .help(direction == .ascending ? String(localized: "ascending") : String(localized: "descending"))
                                    }
                                    Spacer()
                                    Button { isGrid.toggle() } label: {
                                        Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                                            .font(.title3)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(isGrid ? String(localized: "list_view") : String(localized: "grid_view"))
                                }
                                .padding(.horizontal, 20)
                            }

                            if isGrid && searchQuery.isEmpty {
                                VStack(alignment: .leading, spacing: 24) {
                                    ForEach(shelves, id: \.group.rawValue) { shelf in
                                        ArtistReleaseShelf(
                                            title: shelf.group.shelfTitle,
                                            albums: shelf.albums
                                        )
                                    }
                                }
                                .padding(.bottom, 8)
                            } else if searchQuery.isEmpty {
                                LazyVStack(spacing: 0) {
                                    ForEach(displayAlbums) { album in
                                        NavigationLink(value: album) {
                                            AlbumListRow(album: album)
                                                .equatable()
                                        }
                                        .buttonStyle(.plain)
                                        .albumContextMenu(album)
                                        if album.id != displayAlbums.last?.id {
                                            Divider().padding(.leading, 92)
                                        }
                                    }
                                }
                                .padding(.bottom, 8)
                            } else if !displayAlbums.isEmpty {
                                SearchSection(title: String(localized: "albums")) {
                                    LazyVStack(spacing: 0) {
                                        ForEach(displayAlbums) { album in
                                            NavigationLink(value: album) {
                                                AlbumListRow(album: album)
                                                    .equatable()
                                            }
                                            .buttonStyle(.plain)
                                            .albumContextMenu(album)
                                            if album.id != displayAlbums.last?.id {
                                                Divider().padding(.leading, 92)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if !searchQuery.isEmpty {
                            if isLoadingSearchSongs {
                                ProgressView(String(localized: "loading_tracks"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 20)
                            } else if !filteredSongs.isEmpty {
                                SearchSection(title: String(localized: "songs")) {
                                    ForEach(filteredSongs) { song in
                                        SearchSongRow(song: song) {
                                            let index = filteredSongs.firstIndex(where: { $0.id == song.id }) ?? 0
                                            appState.player.play(songs: filteredSongs, startIndex: index)
                                        } onPlayNext: {
                                            appState.player.addPlayNext(song)
                                        } onAddToQueue: {
                                            appState.player.addToQueue(song)
                                        }
                                    }
                                }
                            }
                        }

                        if searchQuery.isEmpty && !vm.similarArtists.isEmpty {
                            similarArtistsSection
                        }

                        if let bio = vm.biography, !bio.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(localized: "more_info"))
                                    .font(.title3.bold())
                                ArtistBiographyBox(biography: bio)
                                    .frame(maxWidth: 640)
                                ArtistLinksRow(lastFmURL: lastFmURL, musicBrainzURL: musicBrainzURL)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
        }
        .navigationTitle(vm.artist?.name ?? artistName)
        .searchable(text: $searchQuery, prompt: String(localized: "search_albums_and_songs"))
        .hidesTitlebarSeparator()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    shareArtist()
                } label: {
                    Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                }
                .help(String(localized: "share"))
                .sharingServicePicker(url: $shareURL)
            }
        }
        .onChange(of: offlineMode.isOffline) { _, isOffline in
            if isOffline && sortOption.requiresServer {
                sortRaw = LibrarySortOption.name.rawValue
            }
            Task { await vm.load(artistId: artistId, artistName: artistName) }
        }
        .onChange(of: downloadStore.songs.count) { _, _ in
            guard offlineMode.isOffline else { return }
            Task { await vm.load(artistId: artistId, artistName: artistName) }
        }
        .task(id: "\(artistId)|\(musicLibraries.revision)") {
            await vm.load(artistId: artistId, artistName: artistName)
        }
        .task(id: songSearchLoadID) {
            guard !searchQuery.isEmpty, !availableAlbums.isEmpty else {
                isLoadingSearchSongs = false
                return
            }
            guard loadedSongSearchSourceID != songSearchSourceID else { return }
            isLoadingSearchSongs = true
            let songs = await vm.fetchSongs(albums: availableAlbums)
            guard !Task.isCancelled else { return }
            artistSongs = songs
            loadedSongSearchSourceID = songSearchSourceID
            isLoadingSearchSongs = false
        }
        .alert(String(localized: "delete_downloads_2"), isPresented: $showDeleteDownloadConfirm) {
            Button(String(localized: "delete"), role: .destructive) {
                for album in vm.albums {
                    downloadStore.deleteAlbum(album.id)
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
        .alert(
            String(localized: "error"),
            isPresented: Binding(get: { shareErrorMessage != nil }, set: { if !$0 { shareErrorMessage = nil } }),
            presenting: shareErrorMessage
        ) { _ in
            Button(String(localized: "ok")) {}
        } message: { message in
            Text(message)
        }
    }

    private var similarArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "fans_also_like"))
                .font(.title3.bold())
                .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(vm.similarArtists) { artist in
                        NavigationLink(value: artist) {
                            VStack(spacing: 8) {
                                CoverArtView(
                                    coverArtID: artist.coverArt,
                                    requestSize: 200,
                                    size: 104,
                                    isCircle: true
                                )
                                Text(artist.name)
                                    .font(.callout)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 104)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.bottom, 8)
    }

    /// Two columns of four, side by side when the window is wide enough,
    /// one scroll apart when it isn't, same shelf as the artist page's
    /// album/singles rows, just for songs instead of covers.
    private static let topSongsGridRows = Array(
        repeating: GridItem(.fixed(60), spacing: 4),
        count: 4
    )
    private static let topSongsStep = 4
    private static let topSongsMinCellWidth: CGFloat = 280
    private static let topSongsMaxCellWidth: CGFloat = 460

    private var topSongsAtStart: Bool { topSongsFirstVisible == 0 }
    private var topSongsAtEnd: Bool { topSongsFirstVisible + Self.topSongsStep >= vm.topSongs.count }
    private var topSongsColumnCount: Int {
        max(1, Int(ceil(Double(vm.topSongs.count) / Double(Self.topSongsStep))))
    }

    private var topSongsSection: some View {
        GeometryReader { geo in
            let columnGaps = CGFloat(max(0, topSongsColumnCount - 1)) * 24
            let perColumnWidth = (geo.size.width - 40 - columnGaps) / CGFloat(topSongsColumnCount)
            let cellWidth = min(max(perColumnWidth, Self.topSongsMinCellWidth), Self.topSongsMaxCellWidth)
            let neededWidth = CGFloat(topSongsColumnCount) * cellWidth + columnGaps + 40
            let needsScrolling = neededWidth > geo.size.width

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text(String(localized: "top_songs"))
                        .font(.title2).bold()
                    Spacer()
                    // Only worth showing once there's actually something to
                    // scroll to: a wide enough window shows every column.
                    if needsScrolling {
                        HStack(spacing: 6) {
                            ShelfNavButton(icon: "chevron.left", disabled: topSongsAtStart) {
                                topSongsFirstVisible = max(0, topSongsFirstVisible - Self.topSongsStep)
                            }
                            ShelfNavButton(icon: "chevron.right", disabled: topSongsAtEnd) {
                                topSongsFirstVisible = min(
                                    max(0, vm.topSongs.count - Self.topSongsStep),
                                    topSongsFirstVisible + Self.topSongsStep
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: Self.topSongsGridRows, spacing: 24) {
                            ForEach(Array(vm.topSongs.enumerated()), id: \.element.id) { index, song in
                                SearchSongRow(
                                    song: song,
                                    rank: index + 1,
                                    isPlaying: appState.player.currentSong?.id == song.id,
                                    showFavorite: showFavoriteActions,
                                    showPlaylist: showPlaylistActions,
                                    isStarred: libraryStore.isSongStarred(song),
                                    showsHoverHighlight: false
                                ) {
                                    appState.player.play(songs: vm.topSongs, startIndex: index)
                                } onPlayNext: {
                                    appState.player.addPlayNext(song)
                                } onAddToQueue: {
                                    appState.player.addToQueue(song)
                                } onFavorite: {
                                    Task { await libraryStore.toggleStarSong(song) }
                                } onAddToPlaylist: {
                                    NotificationCenter.default.post(name: .addSongsToPlaylist, object: [song.id])
                                }
                                .frame(width: cellWidth)
                                .id(song.id)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollDisabled(!needsScrolling)
                    .onChange(of: topSongsFirstVisible) { _, newValue in
                        guard vm.topSongs.indices.contains(newValue) else { return }
                        withAnimation(.easeInOut(duration: 0.28)) {
                            proxy.scrollTo(vm.topSongs[newValue].id, anchor: .leading)
                        }
                    }
                }
            }
        }
        .frame(height: 300)
        .padding(.bottom, 8)
    }

    private func shareArtist() {
        Task {
            do {
                let share = try await SubsonicAPIService.shared.createShare(id: artistId)
                guard let url = URL(string: share.url) else {
                    await MainActor.run { shareErrorMessage = String(localized: "share_link_failed") }
                    return
                }
                await MainActor.run { shareURL = url }
            } catch {
                await MainActor.run { shareErrorMessage = error.localizedDescription }
            }
        }
    }

    private var coverURL: URL? {
        guard let id = vm.artist?.coverArt else { return nil }
        return SubsonicAPIService.shared.coverArtURL(id: id, size: 240)
    }

    private var instantMixArtist: Artist {
        guard let detail = vm.artist else {
            return Artist(id: artistId, name: artistName)
        }
        return Artist(id: detail.id,
                      name: detail.name,
                      albumCount: detail.albumCount,
                      coverArt: detail.coverArt)
    }

    @ViewBuilder
    private func actionButtons(iconOnly: Bool, compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Button {
                Task { await vm.playAll(player: appState.player, albums: displayAlbums, shuffle: false) }
            } label: {
                Group {
                    if vm.isLoadingSongs {
                        ProgressView()
                            .controlSize(.small)
                            .tint(iconOnly ? themeColor : .white)
                            .frame(width: iconOnly ? 18 : nil, height: iconOnly ? 18 : nil)
                    } else {
                        MacPlayActionLabel(iconOnly: iconOnly)
                            .frame(minWidth: iconOnly ? nil : 100)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(themeColor)
            .controlSize(compact ? .regular : .large)
            .disabled(displayAlbums.isEmpty || vm.isLoadingSongs)

            Button {
                Task { await vm.playAll(player: appState.player, albums: displayAlbums, shuffle: true) }
            } label: {
                Label(String(localized: "shuffle"), systemImage: "shuffle")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                    .frame(minWidth: iconOnly ? nil : 100)
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .regular : .large)
            .disabled(displayAlbums.isEmpty || vm.isLoadingSongs)

            if showInstantMixActions && !offlineMode.isOffline {
                Button {
                    InstantMixService.playArtistMix(for: instantMixArtist, player: appState.player)
                } label: {
                    Label(String(localized: "instant_mix"), systemImage: "sparkles")
                        .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .regular : .large)
                .disabled(vm.isLoading)
            }

            Button {
                Task {
                    let songs = await vm.fetchSongs(albums: displayAlbums)
                    guard !songs.isEmpty else { return }
                    appState.player.addPlayNext(songs)
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                }
            } label: {
                Label(String(localized: "play_next"), systemImage: "text.insert")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .regular : .large)
            .disabled(displayAlbums.isEmpty || vm.isLoadingSongs)

            Button {
                Task {
                    let songs = await vm.fetchSongs(albums: displayAlbums)
                    guard !songs.isEmpty else { return }
                    appState.player.addToQueue(songs)
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                }
            } label: {
                Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .regular : .large)
            .disabled(displayAlbums.isEmpty || vm.isLoadingSongs)

            if showPlaylistActions {
                Button {
                    Task {
                        let songs = await vm.fetchSongs(albums: displayAlbums)
                        guard !songs.isEmpty else { return }
                        NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                    }
                } label: {
                    Label(String(localized: "add_to_playlist"), systemImage: "music.note.list")
                        .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .regular : .large)
                .disabled(displayAlbums.isEmpty || vm.isLoadingSongs)
            }

            if enableDownloads, let detail = vm.artist {
                artistDownloadButtons(for: detail, iconOnly: iconOnly, compact: compact)
            }

            if showFavoriteActions, let detail = vm.artist {
                let isStarred = libraryStore.starredArtists.contains { $0.id == detail.id }
                Button {
                    Task {
                        await libraryStore.toggleStarArtist(
                            Artist(id: detail.id, name: detail.name,
                                   albumCount: detail.albumCount, coverArt: detail.coverArt,
                                   starred: isStarred ? Date() : nil)
                        )
                    }
                } label: {
                    Image(systemName: isStarred ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(isStarred ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(isStarred
                    ? String(localized: "remove_from_favorites")
                    : String(localized: "add_to_favorites"))
            }
        }
        .macActionButtonShape(compact: compact)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var artistDownloadStatus: AlbumDownloadStatus {
        let albums = vm.albums
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
    private func artistDownloadButtons(for detail: ArtistDetail, iconOnly: Bool, compact: Bool) -> some View {
        let artistModel = Artist(id: detail.id, name: detail.name,
                                 albumCount: detail.albumCount, coverArt: detail.coverArt,
                                 starred: nil)
        switch artistDownloadStatus {
        case .none:
            if !offlineMode.isOffline {
                Button {
                    downloadStore.enqueueArtist(artistModel)
                } label: {
                    Label(String(localized: "download_artist"), systemImage: "arrow.down.circle")
                        .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .regular : .large)
                .tint(themeColor)
            }
        case .partial:
            if !offlineMode.isOffline {
                Button {
                    downloadStore.enqueueArtist(artistModel)
                } label: {
                    Label(String(localized: "download_remaining"), systemImage: "arrow.down.circle")
                        .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .regular : .large)
                .tint(themeColor)
            }
            Button(role: .destructive) {
                showDeleteDownloadConfirm = true
            } label: {
                Label {
                    Text(String(localized: "delete_downloads"))
                } icon: {
                    DeleteDownloadIcon(tint: .red)
                }
                .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .regular : .large)
            .tint(.red)
        case .complete:
            Button(role: .destructive) {
                showDeleteDownloadConfirm = true
            } label: {
                Label {
                    Text(String(localized: "delete_downloads"))
                } icon: {
                    DeleteDownloadIcon(tint: .red)
                }
                .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .regular : .large)
            .tint(.red)
        }
    }
}

@MainActor
class ArtistDetailViewModel: ObservableObject {
    @Published var artist: ArtistDetail?
    @Published var albums: [Album] = []
    @Published var biography: String?
    @Published var topSongs: [Song] = []
    @Published var similarArtists: [Artist] = []
    @Published var musicBrainzId: String?
    @Published var lastFmURLString: String?
    @Published var isLoading: Bool = false
    @Published var isLoadingSongs: Bool = false
    @Published var errorMessage: String?

    private let api = SubsonicAPIService.shared
    private let maxSongs = 200

    func load(artistId: String, artistName: String) async {
        isLoading = true
        errorMessage = nil
        if OfflineModeService.shared.isOffline {
            populateFromLocal(artistId: artistId, artistName: artistName)
            similarArtists = []
            isLoading = false
            return
        }
        do {
            async let artistDetail = api.getArtist(id: artistId)
            async let artistInfo = api.getArtistInfo(
                id: artistId,
                similarArtistCount: ArtistPageLayout.similarArtistCount
            )
            // Started here rather than after the detail arrives, so the shelf is
            // part of the first render instead of popping in a moment later.
            async let serverTopSongs = ArtistTopSongsService.serverRanked(
                artistName: artistName,
                limit: 8
            )
            // Everything is awaited into locals first and only then written to
            // state in one go. Assigning between two awaits lets SwiftUI render in
            // between, which is what made the sections appear one after another.
            let detail = try await artistDetail
            let info = try? await artistInfo
            var loadedTopSongs = await serverTopSongs
            // The fallback ranking is part of the same wait: letting it run after
            // the page is up is exactly what made the shelf appear on its own.
            if loadedTopSongs.isEmpty {
                loadedTopSongs = await ArtistTopSongsService.topSongs(
                    artistName: artistName,
                    albums: detail.album ?? [],
                    limit: 8
                ) { albumID in
                    (try? await SubsonicAPIService.shared.getAlbum(id: albumID).song) ?? []
                }
            }

            artist = detail
            albums = (detail.album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            topSongs = loadedTopSongs
            biography = info?.biography?.strippingHTML
            // Servers can list a track/featured artist with no album of their
            // own here; tapping through would land on an empty artist page.
            similarArtists = (info?.similarArtist ?? []).filter { ($0.albumCount ?? 0) > 0 }
            musicBrainzId = info?.musicBrainzId
            lastFmURLString = info?.lastFmUrl
        } catch {
            let inlineMessage = OfflineModeService.shared.inlineErrorMessage(for: error)
            populateFromLocal(artistId: artistId, artistName: artistName)
            if artist == nil { errorMessage = inlineMessage }
        }
        isLoading = false
    }

    private func populateFromLocal(artistId: String, artistName: String) {
        let local = DownloadStore.shared.artists.first(where: { $0.artistId == artistId })
            ?? DownloadStore.shared.artists.first(where: { $0.name == artistName })
        guard let local else { return }
        let albumsAsModel = local.albums.map { $0.asAlbum() }
        artist = ArtistDetail(id: local.artistId, name: local.name,
                              albumCount: albumsAsModel.count,
                              coverArt: local.coverArtId,
                              album: albumsAsModel)
        albums = albumsAsModel
    }

    func fetchSongs(albums: [Album]) async -> [Song] {
        guard !albums.isEmpty else { return [] }
        isLoadingSongs = true
        defer { isLoadingSongs = false }
        if OfflineModeService.shared.isOffline {
            let albumOrder = albums.map { $0.id }
            let albumIds = Set(albumOrder)
            let songsByAlbum = Dictionary(
                grouping: DownloadStore.shared.songs.filter { albumIds.contains($0.albumId) },
                by: { $0.albumId }
            )
            return albumOrder.flatMap { id in
                (songsByAlbum[id] ?? []).sorted { ($0.track ?? 0) < ($1.track ?? 0) }.map { $0.asSong() }
            }
        }
        do {
            let indexed = Array(albums.enumerated())
            return try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
                for (i, album) in indexed {
                    group.addTask {
                        let s = try await SubsonicAPIService.shared.getAlbum(id: album.id).song ?? []
                        return (i, s)
                    }
                }
                var results: [(Int, [Song])] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
            }
        } catch {
            if !OfflineModeService.shared.presentConnectivityErrorIfNeeded(error, userInitiated: true) {
                NotificationCenter.default.post(name: .showToast, object: String(localized: "playback_failed"))
            }
            return []
        }
    }

    func playAll(player: AudioPlayerService, albums: [Album], shuffle: Bool) async {
        var songs = await fetchSongs(albums: albums)
        guard !songs.isEmpty else { return }
        if shuffle {
            // Shuffling already discards the order, so sample at random.
            if songs.count > maxSongs { songs = Array(songs.shuffled().prefix(maxSongs)) }
            player.playShuffled(songs: songs)
        } else {
            songs = ArtistPlayOrder.songs(topSongs: topSongs, discography: songs)
            // Trim from the end so the top songs survive the cap.
            if songs.count > maxSongs { songs = Array(songs.prefix(maxSongs)) }
            player.play(songs: songs)
        }
    }
}

#Preview {
    NavigationStack {
        ArtistDetailView(artistId: "1", artistName: "Vorschau Künstler")
    }
    .frame(width: 700, height: 550)
    .environmentObject(AppState.shared)
    .environmentObject(LibraryViewModel())
}

private struct ArtistBiographyBox: View {
    let biography: String

    var body: some View {
        Text(biography)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
