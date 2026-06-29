import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    private let player = AudioPlayerService.shared
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage("artistDetailAlbumSort") private var sortRaw = "newest"
    @AppStorage("artistDetailAlbumDirection") private var dirRaw = "descending"
    @AppStorage("artistDetailAlbumIsGrid") private var isGrid = true

    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var navAlbum: Album?

    private var sort: AlbumSortOption { AlbumSortOption(rawValue: sortRaw) ?? .newest }
    private var dir: SortDirection { SortDirection(rawValue: dirRaw) ?? .descending }

    private var displayAlbums: [Album] {
        var result = albums
        switch sort {
        case .alphabetical: result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .newest:       result.sort { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        case .year:         result.sort { ($0.year ?? 0) < ($1.year ?? 0) }
        case .frequent:     result.sort { ($0.playCount ?? 0) < ($1.playCount ?? 0) }
        }
        if dir == .descending { result.reverse() }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                controls
                Group {
                    if isGrid {
                        LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                            ForEach(displayAlbums) { AlbumCard(album: $0) }
                        }
                    } else {
                        albumList
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, 50)
            .padding(.top, 30)
            .padding(.bottom, 50)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $navAlbum) { AlbumDetailView(album: $0) }
        .task {
            if let detail = await LibraryStore.shared.artistDetail(artist) {
                albums = detail.album ?? []
            }
            songs = await LibraryStore.shared.artistSongs(artist)
            isLoading = false
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            CoverArtView(url: artist.coverURL(600), size: 260, isCircle: true)
            Text(artist.name).font(.largeTitle).bold()
            Text("\(albums.count) \(String(localized: "albums"))")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button { player.play(songs: songs, startIndex: 0) } label: {
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
                ForEach(AlbumSortOption.allCases, id: \.rawValue) { opt in
                    Button { sortRaw = opt.rawValue } label: {
                        if sort == opt { Label(opt.label, systemImage: "checkmark") } else { Text(opt.label) }
                    }
                }
            } label: { Label(sort.label, systemImage: "arrow.up.arrow.down") }
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

    private var albumList: some View {
        LazyVStack(spacing: 4) {
            ForEach(displayAlbums) { album in
                AlbumListRow(album: album) { navAlbum = album }
            }
        }
    }
}
