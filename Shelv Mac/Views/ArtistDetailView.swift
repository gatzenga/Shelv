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
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage("enableDownloads") private var enableDownloads = true
    @AppStorage("artistDetailAlbumSort") private var sortRaw: String = LibrarySortOption.recentlyAdded.rawValue
    @AppStorage("artistDetailAlbumDirection") private var directionRaw: String = SortDirection.descending.rawValue
    @AppStorage("artistDetailAlbumIsGrid") private var isGrid: Bool = true
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false
    @Environment(\.themeColor) private var themeColor
    @State private var showDeleteDownloadConfirm = false
    @State private var searchQuery = ""

    private var effectiveShowDownloadsOnly: Bool {
        offlineMode.isOffline || showDownloadsOnly
    }

    private var sortOption: LibrarySortOption {
        LibrarySortOption(rawValue: sortRaw) ?? .recentlyAdded
    }

    private var direction: SortDirection {
        SortDirection(rawValue: directionRaw) ?? .descending
    }

    private var displayAlbums: [Album] {
        let base: [Album]
        if effectiveShowDownloadsOnly {
            let downloadedIds = Set(downloadStore.albums.map { $0.albumId })
            base = vm.albums.filter { downloadedIds.contains($0.id) }
        } else {
            base = vm.albums
        }
        let filtered = searchQuery.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        switch sortOption {
        case .name:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .mostPlayed:
            let sorted = filtered.sorted { ($0.playCount ?? 0) < ($1.playCount ?? 0) }
            return direction == .ascending ? sorted : Array(sorted.reversed())
        case .recentlyAdded:
            let sorted = filtered.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
            return direction == .ascending ? sorted : Array(sorted.reversed())
        case .year:
            let sorted = filtered.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
            return direction == .ascending ? sorted : Array(sorted.reversed())
        }
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
                            CoverArtView(url: coverURL, size: 120, isCircle: true)
                                .shadow(color: .black.opacity(0.2), radius: 10)

                            VStack(alignment: .leading, spacing: 8) {
                                Text(vm.artist?.name ?? artistName)
                                    .font(.title.bold())
                                if let count = vm.artist?.albumCount {
                                    Text(String(format: String(localized: "count_albums_format"), count))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 8)

                                ViewThatFits(in: .horizontal) {
                                    actionButtons(iconOnly: false)
                                    actionButtons(iconOnly: true)
                                }
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)

                        if !vm.albums.isEmpty {
                            HStack(spacing: 8) {
                                Picker(String(localized: "sort"), selection: $sortRaw) {
                                    ForEach(LibrarySortOption.allCases.filter { !offlineMode.isOffline || !$0.requiresServer }, id: \.self) { opt in
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

                            if isGrid {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)],
                                    spacing: 20
                                ) {
                                    ForEach(displayAlbums) { album in
                                        NavigationLink(value: album) {
                                            AlbumGridItem(album: album)
                                        }
                                        .buttonStyle(.plain)
                                        .albumContextMenu(album)
                                    }
                                }
                                .padding(20)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(displayAlbums) { album in
                                        NavigationLink(value: album) {
                                            AlbumListRow(album: album)
                                        }
                                        .buttonStyle(.plain)
                                        .albumContextMenu(album)
                                        if album.id != displayAlbums.last?.id {
                                            Divider().padding(.leading, 92)
                                        }
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                        }

                        if let bio = vm.biography, !bio.isEmpty {
                            ArtistBiographyBox(biography: bio)
                                .frame(maxWidth: 640)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 24)
                        }
                    }
                }
            }
        }
        .navigationTitle(vm.artist?.name ?? artistName)
        .searchable(text: $searchQuery, prompt: String(localized: "search_albums"))
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
        .task(id: artistId) { await vm.load(artistId: artistId, artistName: artistName) }
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
    private func actionButtons(iconOnly: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await vm.playAll(player: appState.player, albums: displayAlbums, shuffle: false) }
            } label: {
                Group {
                    if vm.isLoadingSongs {
                        ProgressView()
                            .controlSize(.small)
                            .tint(iconOnly ? themeColor : .white)
                    } else {
                        Label(String(localized: "play"), systemImage: "play.fill")
                            .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                            .frame(minWidth: iconOnly ? nil : 100)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(themeColor)
            .controlSize(.large)
            .disabled(displayAlbums.isEmpty || vm.isLoadingSongs)

            Button {
                Task { await vm.playAll(player: appState.player, albums: displayAlbums, shuffle: true) }
            } label: {
                Label(String(localized: "shuffle"), systemImage: "shuffle")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                    .frame(minWidth: iconOnly ? nil : 100)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(displayAlbums.isEmpty || vm.isLoadingSongs)

            if showInstantMixActions && !offlineMode.isOffline {
                Button {
                    InstantMixService.playArtistMix(for: instantMixArtist, player: appState.player)
                } label: {
                    Label(String(localized: "instant_mix"), systemImage: "sparkles")
                        .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
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
            .controlSize(.large)
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
            .controlSize(.large)
            .disabled(displayAlbums.isEmpty || vm.isLoadingSongs)

            if enableDownloads, let detail = vm.artist {
                artistDownloadButton(for: detail, iconOnly: iconOnly)
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
    private func artistDownloadButton(for detail: ArtistDetail, iconOnly: Bool) -> some View {
        let artistModel = Artist(id: detail.id, name: detail.name,
                                 albumCount: detail.albumCount, coverArt: detail.coverArt,
                                 starred: nil)
        switch artistDownloadStatus {
        case .none:
            if !offlineMode.isOffline {
                Button {
                    downloadStore.enqueueArtist(artistModel)
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
                    downloadStore.enqueueArtist(artistModel)
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

@MainActor
class ArtistDetailViewModel: ObservableObject {
    @Published var artist: ArtistDetail?
    @Published var albums: [Album] = []
    @Published var biography: String?
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
            isLoading = false
            return
        }
        do {
            async let artistDetail = api.getArtist(id: artistId)
            async let artistInfo = api.getArtistInfo(id: artistId)
            let detail = try await artistDetail
            artist = detail
            albums = (detail.album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            biography = (try? await artistInfo)?.biography?.strippingHTML
        } catch {
            populateFromLocal(artistId: artistId, artistName: artistName)
            if artist == nil { errorMessage = error.localizedDescription }
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
            NotificationCenter.default.post(name: .showToast, object: String(localized: "playback_failed"))
            return []
        }
    }

    func playAll(player: AudioPlayerService, albums: [Album], shuffle: Bool) async {
        var songs = await fetchSongs(albums: albums)
        guard !songs.isEmpty else { return }
        if songs.count > maxSongs { songs = Array(songs.shuffled().prefix(maxSongs)) }
        if shuffle { player.playShuffled(songs: songs) } else { player.play(songs: songs) }
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
