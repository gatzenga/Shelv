import Combine
import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    @ObservedObject var libraryStore = LibraryStore.shared
    @Environment(\.personalizationSwipeConfiguration) private var personalization
    private let downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject private var musicLibraries = MusicLibraryStore.shared
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

    @State private var detail: ArtistDetail?
    @State private var biography: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var currentToast: ShelveToast?
    @State private var searchQuery = ""
    @State private var artistSongs: [Song]?
    @State private var topSongs: [Song] = []
    @State private var similarArtists: [Artist] = []
    @State private var musicBrainzId: String?
    @State private var lastFmURLString: String?
    @State private var releaseGroup: ArtistReleaseGroup = .all
    @State private var isLoadingSearchSongs = false
    @State private var loadedSongSearchSourceID: String?
    @State private var albumToDeleteDownloads: Album?
    @State private var showDeleteArtistDownloadConfirm = false
    @State private var downloadedAlbumCounts: [String: Int] = [:]
    @State private var shareURL: IdentifiableURL?
    @State private var songPlaylistIds: SongPlaylistIds?
    @State private var isShowingArtwork = false

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
            offlineMode.isOffline
                ? sortedAlbums.map {
                    "\($0.id):\(downloadedAlbumCounts[$0.id, default: 0])"
                }.joined(separator: ",")
                : "downloads-ignored",
            sortedAlbums.map(\.id).joined(separator: ",")
        ].joined(separator: "|")
    }

    private var relevantAlbumDownloadCountsPublisher: AnyPublisher<[String: Int], Never> {
        let albumIDs = Set(sortedAlbums.map(\.id))
        return DownloadUIStateHub.shared
            .albumDownloadedCountsPublisher(albumIDs: albumIDs)
    }

    private var songSearchLoadID: String {
        "\(searchQuery.isEmpty ? "idle" : "searching")|\(songSearchSourceID)"
    }

    private var showsTopSongs: Bool {
        searchQuery.isEmpty && !topSongs.isEmpty
    }

    /// The list layout keeps a single list, so it keeps the filter. The grid
    /// layout splits albums and short releases into their own shelves instead.
    private var releaseGroups: [ArtistReleaseGroup] {
        searchQuery.isEmpty ? ArtistDiscography.availableGroups(for: sortedAlbums) : []
    }

    /// Albums and short releases on their own shelves, or one shelf for the
    /// whole discography when splitting would say nothing about it.
    private var shelves: [(group: ArtistReleaseGroup, albums: [Album])] {
        ArtistDiscography.shelfGroups(for: sortedAlbums).compactMap { group in
            let albums = ArtistDiscography.filter(sortedAlbums, to: group)
            return albums.isEmpty ? nil : (group, albums)
        }
    }

    /// Newest by release year, then by the date the server first saw it.
    private var latestRelease: Album? {
        sortedAlbums.max {
            ($0.year ?? 0, $0.created ?? .distantPast) < ($1.year ?? 0, $1.created ?? .distantPast)
        }
    }

    private var lastFmURL: URL? {
        lastFmURLString.flatMap(URL.init(string:))
    }

    private var musicBrainzURL: URL? {
        guard let musicBrainzId, !musicBrainzId.isEmpty else { return nil }
        return URL(string: "https://musicbrainz.org/artist/\(musicBrainzId)")
    }

    /// The albums actually shown: the search filter first, then the
    /// album / singles filter of the discography section.
    private var displayedAlbums: [Album] {
        guard searchQuery.isEmpty else { return filteredAlbums }
        return ArtistDiscography.filter(filteredAlbums, to: releaseGroup)
    }

    /// Albums and play counts the server already reported, in place of the
    /// monthly-listener line a commercial service would show here.
    private var artistSubtitle: String? {
        let albums = detail?.album ?? []
        let albumCount = detail?.albumCount ?? artist.albumCount ?? albums.count
        var parts: [String] = []
        if albumCount > 0 {
            parts.append(String(format: String(localized: "artist_release_count_format"), albumCount))
        }
        let plays = albums.reduce(0) { $0 + ($1.playCount ?? 0) }
        if plays > 0 {
            parts.append(String(format: String(localized: "artist_play_count_format"), plays))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var showsSimilarArtists: Bool {
        searchQuery.isEmpty && !similarArtists.isEmpty
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
            if searchQuery.isEmpty {
                gridBody
            } else {
                listBody
            }
        }

        .searchable(text: $searchQuery, prompt: String(localized: "search_albums_and_songs"))
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
        .fullScreenCover(isPresented: $isShowingArtwork) {
            ArtworkViewerView(coverArtId: artist.coverArt, title: artist.name)
        }
        .sheet(item: $shareURL) { wrapped in
            ActivityShareSheet(items: [wrapped.url])
        }
        .sheet(item: $songPlaylistIds) { item in
            AddToPlaylistSheet(songIds: item.ids)
                .environmentObject(libraryStore)
                .tint(accentColor)
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
        .onReceive(relevantAlbumDownloadCountsPublisher) { counts in
            let albumIDs = Set(sortedAlbums.map(\.id))
            let currentCounts = Dictionary(uniqueKeysWithValues: albumIDs.compactMap { albumID in
                downloadedAlbumCounts[albumID].map { (albumID, $0) }
            })
            guard currentCounts != counts else { return }
            downloadedAlbumCounts = counts
            if offlineMode.isOffline {
                populateFromLocal()
            }
        }
        .task(id: musicLibraries.revision) {
            await loadDetail()
        }
        .task(id: songSearchLoadID) {
            guard !searchQuery.isEmpty, !sortedAlbums.isEmpty else {
                isLoadingSearchSongs = false
                return
            }
            guard loadedSongSearchSourceID != songSearchSourceID else { return }
            isLoadingSearchSongs = true
            let songs = await fetchAllSongs(from: sortedAlbums)
            guard !Task.isCancelled else { return }
            artistSongs = songs
            loadedSongSearchSourceID = songSearchSourceID
            isLoadingSearchSongs = false
        }
    }

    private var artistHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Button {
                    isShowingArtwork = true
                } label: {
                    AlbumArtView(coverArtId: artist.coverArt, size: 300, isCircle: true)
                        .frame(width: 100, height: 100)
                }
                .buttonStyle(.plain)
                .disabled(artist.coverArt == nil)
                .accessibilityLabel(String(localized: "artwork_open"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(artist.name)
                        .font(.title2).bold()
                    if let subtitle = artistSubtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        playButton
                        shuffleButton
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 16)
    }

    private var playButton: some View {
        Button {
            let albums = sortedAlbums
            guard !albums.isEmpty else { return }
            Task {
                let songs = await fetchAllSongs(from: albums)
                guard !songs.isEmpty else { return }
                let ordered = ArtistPlayOrder.songs(topSongs: topSongs, discography: songs)
                player.play(songs: ordered, startIndex: 0)
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
    }

    private var shuffleButton: some View {
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

    /// A real List, not a ScrollView: Top Songs needs genuine List rows for
    /// its swipe actions and long-press menu to render correctly, the same
    /// way they already do for album titles. The album shelves keep their own
    /// horizontal scrolling inside a single row, which List rows support fine.
    private var gridBody: some View {
        List {
            Section {
                artistHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if showsTopSongs {
                Section {
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: Self.topSongsGridRows, spacing: 24) {
                            ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                                ArtistTopSongCell(
                                    rank: index + 1,
                                    song: song,
                                    accentColor: accentColor,
                                    isOffline: offlineMode.isOffline,
                                    isFavorite: libraryStore.isSongStarred(song),
                                    onPlay: {
                                        player.play(songs: topSongs, startIndex: index)
                                    },
                                    onFavorite: {
                                        haptic(.medium)
                                        Task { await libraryStore.toggleStarSong(song) }
                                    },
                                    onAddToPlaylist: {
                                        songPlaylistIds = SongPlaylistIds(ids: [song.id])
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
                                .frame(width: 300)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    HStack {
                        Text(String(localized: "top_songs"))
                            .font(.title3).bold()
                            .textCase(nil)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.leading, 0)
                }
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
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                if let latestRelease {
                    Section {
                        ArtistLatestReleaseCard(album: latestRelease, accentColor: accentColor)
                            .listRowInsets(EdgeInsets(top: 16, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }

                ForEach(Array(shelves.enumerated()), id: \.element.group.rawValue) { index, shelf in
                    Section {
                        ArtistReleaseShelf(
                            title: shelf.group.shelfTitle,
                            albums: shelf.albums,
                            personalization: personalization,
                            sortRaw: $sortRaw,
                            directionRaw: $directionRaw,
                            isOffline: offlineMode.isOffline,
                            accentColor: accentColor
                        )
                        .listRowInsets(
                            index == 0
                                ? EdgeInsets(top: 16, leading: 0, bottom: 0, trailing: 0)
                                : EdgeInsets()
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }

            if showsSimilarArtists {
                Section {
                    ArtistSimilarArtistsRow(artists: similarArtists)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    HStack {
                        Text(String(localized: "fans_also_like"))
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
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    ArtistLinksRow(lastFmURL: lastFmURL, musicBrainzURL: musicBrainzURL)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    HStack {
                        Text(String(localized: "more_info"))
                            .font(.title3).bold()
                            .textCase(nil)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.leading, 0)
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
        .scrollIndicators(.hidden)
    }

    private var listBody: some View {
        List {
            if searchQuery.isEmpty {
                Section {
                    artistHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
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
            } else if !filteredAlbums.isEmpty {
                Section {
                    if !releaseGroups.isEmpty {
                        ArtistReleaseGroupPicker(selection: $releaseGroup, groups: releaseGroups)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                    }

                    ForEach(displayedAlbums) { album in
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
                        Text(String(localized: searchQuery.isEmpty ? "discography" : "albums"))
                            .font(.title3).bold()
                            .textCase(nil)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.leading, 0)
                }
            }

            if !searchQuery.isEmpty {
                if isLoadingSearchSongs {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else if !filteredSongs.isEmpty {
                    Section(String(localized: "songs")) {
                        ForEach(Array(filteredSongs.enumerated()), id: \.element.id) { index, song in
                            Button {
                                player.play(songs: filteredSongs, startIndex: index)
                            } label: {
                                LibraryStarredSongRow(song: song)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if showsSimilarArtists {
                Section {
                    ArtistSimilarArtistsRow(artists: similarArtists)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    HStack {
                        Text(String(localized: "fans_also_like"))
                            .font(.title3).bold()
                            .textCase(nil)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
            }

            if let bio = biography, !bio.isEmpty {
                Section {
                    ArtistBiographyBox(biography: bio, accentColor: accentColor)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    HStack {
                        Text(String(localized: "more_info"))
                            .font(.title3).bold()
                            .textCase(nil)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
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
        let status = albumDownloadStatus(album, counts: downloadedAlbumCounts)
        switch status {
        case .none, .partial:
            return offlineMode.isOffline ? .hidden : .download
        case .complete:
            return .delete
        }
    }

    private func handleAlbumDownloadSwipe(_ album: Album) {
        guard enableDownloads else { return }
        let status = albumDownloadStatus(
            album,
            counts: [album.id: DownloadUIStateHub.shared.albumDownloadedCount(album.id)]
        )
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
            HStack(spacing: 4) {
                AlbumFavoriteBadge(albumId: album.id)
                AlbumDownloadBadge(albumId: album.id, style: .list)
            }
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

            if enableDownloads
                && (!offlineMode.isOffline || artistDownloadStatus != .none) {
                Divider()
                artistDownloadMenuItems
            }

            if !(enableDownloads && artistDownloadStatus != .none) {
                Divider()
                shareMenuItem
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
        // Offline there is nothing to wait for, so local data goes up right away.
        // Online it is only used as a fallback if the request fails: showing it
        // up front would put the albums on screen before the rest of the page.
        guard !offlineMode.isOffline else {
            populateFromLocal()
            topSongs = []
            similarArtists = []
            isLoading = false
            return
        }
        isLoading = detail == nil
        do {
            async let artistDetail = SubsonicAPIService.shared.getArtist(id: artist.id)
            async let artistInfo = SubsonicAPIService.shared.getArtistInfo(
                id: artist.id,
                similarArtistCount: ArtistPageLayout.similarArtistCount
            )
            // Started here rather than after the detail arrives, so the shelf is
            // part of the first render instead of popping in a moment later.
            async let serverTopSongs = ArtistTopSongsService.serverRanked(
                artistName: artist.name,
                limit: Self.topSongsCarouselLimit
            )
            // Everything is awaited into locals first and only then written to
            // state in one go. Assigning between two awaits lets SwiftUI render in
            // between, which is what made the sections appear one after another.
            let loadedDetail = try await artistDetail
            let info = try? await artistInfo
            var loadedTopSongs = await serverTopSongs
            // The fallback ranking is part of the same wait: letting it run after
            // the page is up is exactly what made the shelf appear on its own.
            if loadedTopSongs.isEmpty {
                loadedTopSongs = await ArtistTopSongsService.topSongs(
                    artistName: artist.name,
                    albums: loadedDetail.album ?? [],
                    limit: Self.topSongsCarouselLimit
                ) { albumID in
                    (try? await SubsonicAPIService.shared.getAlbum(id: albumID).song) ?? []
                }
            }

            detail = loadedDetail
            topSongs = loadedTopSongs
            biography = info?.biography?.strippingHTML
            // Servers can list a track/featured artist with no album of their
            // own here; tapping through would land on an empty artist page.
            similarArtists = (info?.similarArtist ?? []).filter { ($0.albumCount ?? 0) > 0 }
            musicBrainzId = info?.musicBrainzId
            lastFmURLString = info?.lastFmUrl
            isLoading = false
        } catch {
            populateFromLocal()
            if detail == nil {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    /// Rows in the Top Songs shelf: two columns of four, side by side when
    /// the screen is wide enough, one swipe apart when it isn't.
    private static let topSongsCarouselLimit = 8
    private static let topSongsGridRows = Array(
        repeating: GridItem(.fixed(56), spacing: 4),
        count: 4
    )

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
            let status = albumDownloadStatus(album, counts: downloadedAlbumCounts)
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

    private func albumDownloadStatus(
        _ album: Album,
        counts: [String: Int]
    ) -> AlbumDownloadStatus {
        let totalSongs = album.songCount ?? 0
        let downloaded = counts[album.id, default: 0]
        if downloaded == 0 { return .none }
        if downloaded >= totalSongs { return .complete }
        return .partial(downloaded: downloaded, total: totalSongs)
    }

    @ViewBuilder
    private var artistDownloadMenuItems: some View {
        switch artistDownloadStatus {
        case .none:
            if !offlineMode.isOffline {
                Button {
                    haptic()
                    Task {
                        await DownloadService.shared.enqueueArtist(
                            artist: artist,
                            serverId: serverStableId()
                        )
                    }
                    currentToast = ShelveToast(message: String(localized: "download_started"))
                } label: {
                    Label(String(localized: "download_artist"), systemImage: "arrow.down.circle")
                        .foregroundStyle(accentColor)
                }
                .tint(accentColor)
            }
        case .partial:
            if !offlineMode.isOffline {
                Button {
                    haptic()
                    Task {
                        await DownloadService.shared.enqueueArtist(
                            artist: artist,
                            serverId: serverStableId()
                        )
                    }
                    currentToast = ShelveToast(message: String(localized: "download_started"))
                } label: {
                    Label(String(localized: "download_remaining"), systemImage: "arrow.down.circle")
                        .foregroundStyle(accentColor)
                }
                .tint(accentColor)
            }
            shareMenuItem
            deleteArtistDownloadMenuItem
        case .complete:
            shareMenuItem
            deleteArtistDownloadMenuItem
        }
    }

    private var deleteArtistDownloadMenuItem: some View {
        Button(role: .destructive) {
            haptic()
            showDeleteArtistDownloadConfirm = true
        } label: {
            Label {
                Text(String(localized: "delete_downloads_2"))
            } icon: {
                DeleteDownloadIcon(tint: .red)
            }
        }
        .tint(.red)
    }

    private var shareMenuItem: some View {
        Button {
            shareArtist()
        } label: {
            Label(String(localized: "share"), systemImage: "square.and.arrow.up")
        }
    }

    private func shareArtist() {
        Task {
            do {
                let share = try await SubsonicAPIService.shared.createShare(id: artist.id)
                guard let url = URL(string: share.url) else {
                    await MainActor.run {
                        currentToast = ShelveToast(message: String(localized: "share_link_failed"), isError: true)
                    }
                    return
                }
                await MainActor.run { shareURL = IdentifiableURL(url: url) }
            } catch {
                await MainActor.run {
                    currentToast = ShelveToast(message: error.localizedDescription, isError: true)
                }
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

private struct SongPlaylistIds: Identifiable {
    let id = UUID()
    let ids: [String]
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
