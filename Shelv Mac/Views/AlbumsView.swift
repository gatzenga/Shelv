import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var vm = LibraryViewModel.shared
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("albumViewIsGrid") private var isGrid: Bool = true
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false
    @AppStorage(PersonalizationPreferenceKey.showGenreFilter) private var showGenreFilter = true
    @AppStorage(PersonalizationPreferenceKey.albumGenreFilter) private var albumGenreFilter: String = ""
    @State private var searchText: String = ""
    @State private var displayAlbums: [Album] = []
    @State private var genreOptions: [AlbumGenreFilterOption] = []
    @State private var displayRebuildTask: Task<Void, Never>?
    @State private var displayRebuildGeneration = 0
    @State private var playbackTask: Task<Void, Never>?
    @State private var isPreparingPlayback = false
    @State private var playbackPreparationIsShuffled = false

    private var effectiveShowDownloadsOnly: Bool {
        offlineMode.isOffline || showDownloadsOnly
    }

    private var genreSelection: Binding<String> {
        Binding(
            get: { AlbumGenreFilterOption.selectedGenre(albumGenreFilter, in: genreOptions) ?? "" },
            set: { albumGenreFilter = $0 }
        )
    }

    private var sortSelection: Binding<LibrarySortOption> {
        Binding(
            get: { vm.sortOption },
            set: { vm.selectAlbumSortOption($0) }
        )
    }

    @ViewBuilder
    private var playbackButtons: some View {
        Button {
            prepareVisibleAlbumsForPlayback(shuffled: false)
        } label: {
            Group {
                if isPreparingPlayback && !playbackPreparationIsShuffled {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                        .font(.title3)
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(displayAlbums.isEmpty || isPreparingPlayback)
        .help(String(localized: "play"))
        .accessibilityLabel(String(localized: "play"))

        Button {
            prepareVisibleAlbumsForPlayback(shuffled: true)
        } label: {
            Group {
                if isPreparingPlayback && playbackPreparationIsShuffled {
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
        .disabled(displayAlbums.isEmpty || isPreparingPlayback)
        .help(String(localized: "shuffle"))
        .accessibilityLabel(String(localized: "shuffle"))
    }

    private func rebuildDisplayAlbums(
        sortedAlbumsOverride: [Album]? = nil,
        downloadedAlbumsOverride: [DownloadedAlbum]? = nil
    ) {
        displayRebuildTask?.cancel()
        displayRebuildGeneration &+= 1
        let generation = displayRebuildGeneration
        let isOffline = offlineMode.isOffline
        let downloadsOnly = effectiveShowDownloadsOnly
        let latestSortedAlbums = sortedAlbumsOverride ?? vm.sortedAlbums
        let sortedAlbums = latestSortedAlbums.isEmpty && !vm.albums.isEmpty ? vm.albums : latestSortedAlbums
        let serverAlbumsEmpty = vm.albums.isEmpty
        let downloadedAlbumRecords = downloadedAlbumsOverride ?? downloadStore.albums
        let downloadedAlbums = downloadedAlbumRecords.map { $0.asAlbum() }
        let downloadedIds = Set(downloadedAlbumRecords.map { $0.albumId })
        let query = searchText
        let selectedGenre = showGenreFilter
            ? AlbumGenreFilterOption.normalizedGenre(albumGenreFilter)
            : nil

        displayRebuildTask = Task.detached(priority: .userInitiated) {
            let baseAlbums: [Album]
            if isOffline && serverAlbumsEmpty {
                baseAlbums = downloadedAlbums
            } else if downloadsOnly {
                baseAlbums = sortedAlbums.filter { downloadedIds.contains($0.id) }
            } else {
                baseAlbums = sortedAlbums
            }

            let nextGenreOptions = AlbumGenreFilterOption.options(from: baseAlbums)
            let effectiveSelectedGenre = AlbumGenreFilterOption.selectedGenre(
                selectedGenre,
                in: nextGenreOptions
            )
            let genreFilteredAlbums: [Album]
            if let effectiveSelectedGenre {
                genreFilteredAlbums = baseAlbums.filter {
                    AlbumGenreFilterOption.matches($0, selectedGenre: effectiveSelectedGenre)
                }
            } else {
                genreFilteredAlbums = baseAlbums
            }

            let result: [Album]
            if query.isEmpty {
                result = genreFilteredAlbums
            } else {
                result = genreFilteredAlbums.filter {
                    $0.name.localizedCaseInsensitiveContains(query) ||
                    ($0.artist?.localizedCaseInsensitiveContains(query) ?? false)
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard displayRebuildGeneration == generation else { return }
                displayAlbums = result
                genreOptions = nextGenreOptions
            }
        }
    }

    private func prepareVisibleAlbumsForPlayback(shuffled: Bool) {
        let albums = displayAlbums
        guard !albums.isEmpty else { return }

        playbackTask?.cancel()
        playbackPreparationIsShuffled = shuffled
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
            let songs = await LibraryPlaybackQueueBuilder.songs(
                from: albums,
                shuffled: shuffled
            ) { album in
                if useDownloadedSongs {
                    return downloadedSongsByAlbumID[album.id] ?? []
                }
                if let songs = album.songs {
                    return songs
                }
                return (try? await api.getAlbum(id: album.id, retries: 1).song) ?? []
            }

            guard !Task.isCancelled, api.activeServer?.id == serverID else {
                isPreparingPlayback = false
                return
            }

            isPreparingPlayback = false
            playbackTask = nil

            guard !songs.isEmpty else {
                NotificationCenter.default.post(
                    name: .showToast,
                    object: String(localized: "playback_failed")
                )
                return
            }

            if shuffled {
                player.playShuffled(songs: songs)
            } else {
                player.play(songs: songs)
            }
        }
    }

    private func cancelPlaybackPreparation() {
        playbackTask?.cancel()
        playbackTask = nil
        isPreparingPlayback = false
    }

    var body: some View {
        let displayAlbums = self.displayAlbums
        let lastAlbumID = displayAlbums.last?.id

        VStack(spacing: 0) {
            HStack {
                TextField(String(localized: "filter"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                if showGenreFilter {
                    Picker("\(String(localized: "genre")):", selection: genreSelection) {
                        Text(String(localized: "all_genres")).tag("")
                        ForEach(genreOptions) { option in
                            Text(option.label).tag(option.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                    .frame(width: 180)
                }
                Picker("\(String(localized: "sort")):", selection: sortSelection) {
                    ForEach(LibrarySortOption.allCases.filter { !offlineMode.isOffline || !$0.requiresServer }, id: \.self) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .frame(width: 180)
                if vm.sortOption.allowsDirection {
                    Button {
                        vm.albumSortDirection = vm.albumSortDirection == .ascending ? .descending : .ascending
                    } label: {
                        Image(systemName: vm.albumSortDirection == .ascending ? "arrow.up" : "arrow.down")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help(vm.albumSortDirection == .ascending ? String(localized: "ascending") : String(localized: "descending"))
                }
                Button { isGrid.toggle() } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help(isGrid ? String(localized: "list_view") : String(localized: "grid_view"))
                playbackButtons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if vm.isLoadingAlbums {
                ProgressView(String(localized: "loading_albums"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)], spacing: 20) {
                        ForEach(displayAlbums) { album in
                            NavigationLink(value: album) {
                                AlbumGridItem(album: album)
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album)
                        }
                    }
                    .padding(20)
                }
                .overlay {
                    if displayAlbums.isEmpty && !vm.albums.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayAlbums) { album in
                            NavigationLink(value: album) {
                                AlbumListRow(album: album)
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album)
                            if album.id != lastAlbumID {
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .overlay {
                    if displayAlbums.isEmpty && !vm.albums.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }

            if let err = vm.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding()
            }
        }
        .navigationTitle(String(format: String(localized: "albums_count_format"), displayAlbums.count))
        .onAppear { rebuildDisplayAlbums() }
        .onReceive(vm.$sortedAlbums) { rebuildDisplayAlbums(sortedAlbumsOverride: $0) }
        .onReceive(downloadStore.catalogPublisher) { _ in
            rebuildDisplayAlbums(downloadedAlbumsOverride: downloadStore.albums)
        }
        .onChange(of: searchText) { _, _ in rebuildDisplayAlbums() }
        .onChange(of: albumGenreFilter) { _, _ in rebuildDisplayAlbums() }
        .onChange(of: showGenreFilter) { _, enabled in
            if !enabled { albumGenreFilter = "" }
            rebuildDisplayAlbums()
        }
        .onChange(of: showDownloadsOnly) { _, _ in rebuildDisplayAlbums() }
        .onChange(of: offlineMode.isOffline) { _, isOffline in
            if isOffline && vm.sortOption.requiresServer {
                vm.sortOption = .name
            }
            rebuildDisplayAlbums()
        }
        .onDisappear {
            displayRebuildTask?.cancel()
            displayRebuildTask = nil
            cancelPlaybackPreparation()
        }
        .task { await vm.loadAlbums() }
    }
}

struct AlbumGridItem: View, Equatable {
    let album: Album
    @State private var isHovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.album == rhs.album
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                CoverArtView(
                    coverArtID: album.coverArt,
                    requestSize: 200,
                    size: 160,
                    cornerRadius: 8
                )
                    .shadow(color: .black.opacity(isHovered ? 0.3 : 0.12), radius: isHovered ? 10 : 4)
                    .scaleEffect(isHovered ? 1.03 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
                AlbumDownloadBadge(albumId: album.id)
                    .padding(6)
            }
            Text(album.name)
                .font(.caption.bold())
                .lineLimit(1)
            if let artist = album.artist {
                Text(artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(album.year.map(String.init) ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 160, alignment: .topLeading)
        .onHover { isHovered = $0 }
    }
}

struct AlbumListRow: View, Equatable {
    let album: Album
    @State private var isHovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.album == rhs.album
    }

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(
                coverArtID: album.coverArt,
                requestSize: 120,
                size: 52,
                cornerRadius: 6
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let artist = album.artist {
                        Text(artist)
                            .lineLimit(1)
                    }
                    if album.artist != nil, album.year != nil {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    if let year = album.year {
                        Text(String(year))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            AlbumDownloadBadge(albumId: album.id)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color(NSColor.windowBackgroundColor)
            if isHovered {
                Color.primary.opacity(0.05)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

#Preview {
    AlbumsView()
        .frame(width: 900, height: 700)
        .environmentObject(AppState.shared)
        .environmentObject(LibraryViewModel())
}
