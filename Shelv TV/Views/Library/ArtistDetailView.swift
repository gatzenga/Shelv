import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    private let player = AudioPlayerService.shared
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @ObservedObject private var musicLibraries = MusicLibraryStore.shared
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage("artistDetailAlbumSort") private var sortRaw = "newest"
    @AppStorage("artistDetailAlbumDirection") private var dirRaw = "descending"
    @AppStorage("artistDetailAlbumIsGrid") private var isGrid = true

    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var topSongs: [Song] = []
    @State private var similarArtists: [Artist] = []
    @State private var isLoading = true
    @State private var navAlbum: Album?
    @State private var showAddToPlaylist = false

    private var sort: AlbumSortOption { AlbumSortOption(rawValue: sortRaw) ?? .newest }
    private var dir: SortDirection { SortDirection(rawValue: dirRaw) ?? .descending }

    /// Releases and plays, from data the page already has, same line as
    /// iOS/macOS, in place of the album-count-only text this used to be.
    private var artistSubtitle: String {
        var parts: [String] = []
        if !albums.isEmpty {
            parts.append(String(format: String(localized: "artist_release_count_format"), albums.count))
        }
        let plays = albums.reduce(0) { $0 + ($1.playCount ?? 0) }
        if plays > 0 {
            parts.append(String(format: String(localized: "artist_play_count_format"), plays))
        }
        return parts.isEmpty ? "\(albums.count) \(String(localized: "albums"))" : parts.joined(separator: " · ")
    }

    private var displayAlbums: [Album] {
        ArtistAlbumPlaybackOrder.sorted(
            albums,
            preference: ArtistAlbumSortPreference(
                sortRaw: sortRaw,
                directionRaw: dirRaw
            )
        )
    }

    /// Albums and short releases on their own shelves, or one shelf for the whole
    /// discography when splitting would say nothing about it. Same rule as iPhone
    /// and Mac, so an artist reads the same on every screen.
    private var shelves: [(group: ArtistReleaseGroup, albums: [Album])] {
        ArtistDiscography.shelfGroups(for: displayAlbums).compactMap { group in
            let albums = ArtistDiscography.filter(displayAlbums, to: group)
            return albums.isEmpty ? nil : (group, albums)
        }
    }

    private var latestRelease: Album? {
        displayAlbums.max {
            ($0.year ?? 0, $0.created ?? .distantPast) < ($1.year ?? 0, $1.created ?? .distantPast)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                controls
                if !topSongs.isEmpty {
                    topSongsSection
                }
                if let latestRelease {
                    latestReleaseCard(latestRelease)
                }
                ForEach(shelves, id: \.group.rawValue) { shelf in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(shelf.group.shelfTitle)
                            .font(.title3).bold()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Group {
                            if isGrid {
                                // Every release on screen at once. A television has the
                                // room, so there is nothing to hide behind a "show all".
                                LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                                    ForEach(shelf.albums) { AlbumCard(album: $0, showsArtist: false) }
                                }
                            } else {
                                albumList(shelf.albums)
                            }
                        }
                        .focusSection()
                    }
                }
                if !similarArtists.isEmpty {
                    similarArtistsSection
                }
            }
            .padding(.horizontal, 50)
            .padding(.top, 30)
            .padding(.bottom, 50)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $navAlbum) { AlbumDetailView(album: $0) }
        .addToPlaylistDialog(isPresented: $showAddToPlaylist, songIds: songs.map(\.id))
        .task(id: musicLibraries.revision) {
            // All four run at once and the page is only revealed once they are in,
            // so Top Songs and Similar Artists are part of the first render rather
            // than popping in one after the other.
            async let detailResult = LibraryStore.shared.artistDetail(artist)
            async let songsResult = LibraryStore.shared.artistSongs(artist)
            async let topSongsResult = serverTopSongs()
            async let infoResult = artistInfo()

            // Awaited into locals first and only then written to state in one go.
            // Assigning between two awaits lets SwiftUI render in between, which is
            // what made the sections appear one after another.
            let loadedDetail = await detailResult
            let loadedSongs = await songsResult
            var loadedTopSongs = await topSongsResult
            let info = await infoResult

            // The fallback ranking is part of the same wait: letting it run after
            // the page is up is exactly what made the shelf appear on its own.
            if !offlineMode.isOffline, loadedTopSongs.isEmpty {
                loadedTopSongs = await ArtistTopSongsService.topSongs(
                    artistName: artist.name,
                    albums: loadedDetail?.album ?? [],
                    limit: 8
                ) { albumID in
                    (try? await SubsonicAPIService.shared.getAlbum(id: albumID).song) ?? []
                }
            }

            albums = loadedDetail?.album ?? []
            songs = loadedSongs
            topSongs = loadedTopSongs
            // Servers can list a track/featured artist with no album of their
            // own here; tapping through would land on an empty artist page.
            similarArtists = (info?.similarArtist ?? []).filter { ($0.albumCount ?? 0) > 0 }
            isLoading = false
        }
    }

    private func serverTopSongs() async -> [Song] {
        guard !offlineMode.isOffline else { return [] }
        return await ArtistTopSongsService.serverRanked(artistName: artist.name, limit: 8)
    }

    private func artistInfo() async -> ArtistInfo? {
        guard !offlineMode.isOffline else { return nil }
        return try? await SubsonicAPIService.shared.getArtistInfo(
            id: artist.id,
            similarArtistCount: ArtistPageLayout.similarArtistCount
        )
    }

    private static let topSongsRowHeight: CGFloat = 76
    private static let topSongsRowSpacing: CGFloat = 12
    private static let topSongsColumnSpacing: CGFloat = 40
    private static let topSongsGridRows = Array(
        repeating: GridItem(.fixed(topSongsRowHeight), spacing: topSongsRowSpacing),
        count: 4
    )

    /// Same ranking as iOS/macOS: two columns of four, spanning the screen's
    /// full, fixed 16:9 width instead of a fixed card width, since a TV
    /// screen doesn't resize, so there's no case where this needs to scroll.
    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "top_songs"))
                .font(.title3).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geo in
                let columnWidth = (geo.size.width - Self.topSongsColumnSpacing) / 2
                LazyHGrid(rows: Self.topSongsGridRows, spacing: Self.topSongsColumnSpacing) {
                    ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                        DetailSongRow(
                            song: song,
                            number: index,
                            showArtwork: true,
                            rank: index + 1,
                            rankColumnWidth: 26,
                            rankColumnAlignment: .leading
                        ) {
                            player.play(songs: topSongs, startIndex: index)
                        }
                        .frame(width: columnWidth)
                    }
                }
            }
            .frame(height: 4 * Self.topSongsRowHeight + 3 * Self.topSongsRowSpacing)
        }
        .focusSection()
    }

    /// Same server data as iOS/macOS, same per-artist long-press menu as
    /// every other tvOS artist card (`ArtistCard` wires that up on its own).
    private var similarArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "fans_also_like"))
                .font(.title3).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 30) {
                    ForEach(similarArtists) { artist in
                        ArtistCard(artist: artist, size: 180)
                    }
                }
                // ArtistCard scales up 12% and casts a 24pt shadow on focus,
                // so it needs headroom on every side the ScrollView clips,
                // not just top: the first/last card's own left/right edges too.
                .padding(.horizontal, 40)
                .padding(.top, 40)
            }
        }
        .focusSection()
    }

    private var header: some View {
        VStack(spacing: 18) {
            CoverArtView(url: artist.coverURL(600), size: 260, isCircle: true)
            Text(artist.name)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            Text(artistSubtitle)
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button {
                    let ordered = ArtistPlayOrder.songs(topSongs: topSongs, discography: songs)
                    player.play(songs: ordered, startIndex: 0)
                } label: {
                    Label(String(localized: "play"), systemImage: "play.fill")
                }
                .disabled(songs.isEmpty)
                Button { player.playShuffled(songs: songs) } label: {
                    Label(String(localized: "shuffle"), systemImage: "shuffle")
                }
                .disabled(songs.isEmpty)
                if showInstantMixActions && !offlineMode.isOffline {
                    Button {
                        InstantMixService.playArtistMix(for: artist, player: player)
                    } label: {
                        Label(String(localized: "instant_mix"), systemImage: "sparkles")
                    }
                }
                if showFavoriteActions {
                    let starred = library.isArtistStarred(artist)
                    Button { Task { await library.toggleStarArtist(artist) } } label: {
                        Label(starred ? String(localized: "unfavorite") : String(localized: "favorite"),
                              systemImage: starred ? "heart.fill" : "heart")
                    }
                }
                if showPlaylistActions {
                    Button { showAddToPlaylist = true } label: {
                        Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                    }
                    .disabled(songs.isEmpty)
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.bottom, 10)
        .focusSection()
    }

    private var controls: some View {
        HStack(spacing: 24) {
            Menu {
                ForEach(AlbumSortOption.allCases.filter { $0 != .artist }, id: \.rawValue) { opt in
                    Button { sortRaw = opt.rawValue } label: {
                        if sort == opt { Label(opt.label, systemImage: "checkmark") } else { Text(opt.label) }
                    }
                }
            } label: { Label("\(String(localized: "sort")): \(sort.label)", systemImage: "arrow.up.arrow.down") }
            Button { dirRaw = dir == .ascending ? "descending" : "ascending" } label: {
                Image(systemName: dir.icon)
            }
            Button { isGrid.toggle() } label: {
                Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
            }
        }
        .buttonStyle(.bordered)
        .focusSection()
    }

    private func albumList(_ albums: [Album]) -> some View {
        LazyVStack(spacing: 4) {
            ForEach(albums) { album in
                AlbumListRow(album: album, showsArtist: false) { navAlbum = album }
            }
        }
    }

    /// The newest release, called out above the shelves. Sorting never moves it,
    /// so it sits above the sort control's reach, the way it does on the Mac.
    private func latestReleaseCard(_ album: Album) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            HStack(spacing: 24) {
                CoverArtView(url: album.coverURL(500), size: 140, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "latest_release"))
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)
                    Text(album.name)
                        .font(.title3).bold()
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !album.displayYear.isEmpty {
                        Text(album.displayYear)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .buttonStyle(.card)
        .focusSection()
    }
}

extension ArtistReleaseGroup {
    /// Shelf heading. `.all` carries the whole discography, so it takes the
    /// discography wording rather than asserting a release type nobody declared.
    var shelfTitle: String {
        switch self {
        case .all: String(localized: "discography")
        case .albums: String(localized: "albums")
        case .singlesAndEPs: String(localized: "release_group_singles_eps")
        }
    }
}
