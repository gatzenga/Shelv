import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject var libraryStore: LibraryStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("artistDetailAlbumSort") private var sortRaw: String = AlbumSortOption.newest.rawValue
    @AppStorage("artistDetailAlbumDirection") private var directionRaw: String = SortDirection.descending.rawValue
    @AppStorage("artistDetailAlbumIsGrid") private var isGrid: Bool = true

    @State private var detail: ArtistDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var currentToast: ShelveToast?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    private var sortOption: AlbumSortOption {
        AlbumSortOption(rawValue: sortRaw) ?? .newest
    }

    private var direction: SortDirection {
        SortDirection(rawValue: directionRaw) ?? .descending
    }

    private static let sortArticles: [String] = [
        "the ", "an ", "a ",
        "der ", "die ", "das ", "dem ", "den ", "des ",
        "eine ", "einer ", "einem ", "einen ", "ein ",
        "les ", "le ", "la ", "l\u{2019}", "l'",
        "une ", "un ",
        "los ", "las ", "el ", "una ",
        "gli ", "uno ", "il ", "lo ",
        "umas ", "uma ", "uns ", "um ", "os ", "as ",
        "het ", "een ", "de ",
    ]

    private func sortKey(for name: String) -> String {
        let lower = name.lowercased()
        for article in Self.sortArticles {
            if lower.hasPrefix(article) {
                return String(name.dropFirst(article.count))
            }
        }
        return name
    }

    private var sortedAlbums: [Album] {
        guard let albums = detail?.album else { return [] }
        switch sortOption {
        case .alphabetical:
            // Name immer A-Z, unabhängig von direction
            return albums.sorted {
                sortKey(for: $0.name).localizedCaseInsensitiveCompare(sortKey(for: $1.name)) == .orderedAscending
            }
        case .frequent:
            let base = albums.sorted { ($0.playCount ?? 0) < ($1.playCount ?? 0) }
            return direction == .ascending ? base : Array(base.reversed())
        case .newest, .year:
            let base = albums.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
            return direction == .ascending ? base : Array(base.reversed())
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    AlbumArtView(coverArtId: artist.coverArt, size: 300, isCircle: true)
                        .frame(width: 100, height: 100)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(artist.name)
                            .font(.title2).bold()
                        if let count = artist.albumCount {
                            Text("\(count) \(tr("Albums", "Alben"))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button {
                                guard let albums = detail?.album, !albums.isEmpty else { return }
                                Task {
                                    let songs = await fetchAllSongs(from: albums)
                                    guard !songs.isEmpty else { return }
                                    player.play(songs: songs, startIndex: 0)
                                }
                            } label: {
                                Label(tr("Play", "Abspielen"), systemImage: "play.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accentColor)
                            .disabled(isLoading)

                            Button {
                                guard let albums = detail?.album, !albums.isEmpty else { return }
                                Task {
                                    let songs = await fetchAllSongs(from: albums)
                                    guard !songs.isEmpty else { return }
                                    player.playShuffled(songs: songs)
                                }
                            } label: {
                                Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(accentColor)
                            .disabled(isLoading)
                        }
                    }
                }
                .padding(.horizontal)

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
                    Text(tr("Albums", "Alben"))
                        .font(.title3).bold()
                        .padding(.horizontal)

                    if isGrid {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(sortedAlbums) { album in
                                NavigationLink(destination: AlbumDetailView(album: album)) {
                                    AlbumCardView(album: album, showArtist: false, showYear: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(sortedAlbums) { album in
                                NavigationLink(destination: AlbumDetailView(album: album)) {
                                    albumListRow(album)
                                }
                                .buttonStyle(.plain)
                                if album.id != sortedAlbums.last?.id {
                                    Divider().padding(.leading, 76)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                PlayerBottomSpacer()
            }
            .padding(.top, 16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if enableFavorites {
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
        .task {
            await loadDetail()
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
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var artistMenu: some View {
        Menu {
            Button {
                guard let albums = detail?.album, !albums.isEmpty else { return }
                Task {
                    let songs = await fetchAllSongs(from: albums)
                    guard !songs.isEmpty else { return }
                    player.addPlayNext(songs)
                    currentToast = ShelveToast(message: tr("Added as next", "Als nächstes"))
                }
            } label: {
                Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
            }
            .disabled(isLoading)

            Button {
                guard let albums = detail?.album, !albums.isEmpty else { return }
                Task {
                    let songs = await fetchAllSongs(from: albums)
                    guard !songs.isEmpty else { return }
                    player.addToQueue(songs)
                    currentToast = ShelveToast(message: tr("Added to queue", "Zur Warteschlange"))
                }
            } label: {
                Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
            }
            .disabled(isLoading)

            if enablePlaylists {
                Button {
                    guard let albums = detail?.album, !albums.isEmpty else { return }
                    Task {
                        let songs = await fetchAllSongs(from: albums)
                        guard !songs.isEmpty else { return }
                        NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                    }
                } label: {
                    Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list")
                }
                .disabled(isLoading)
            }

            Divider()

            Button { isGrid.toggle() } label: {
                Label(
                    isGrid ? tr("List view", "Listenansicht") : tr("Grid view", "Rasteransicht"),
                    systemImage: isGrid ? "list.bullet" : "square.grid.2x2"
                )
            }

            Divider()

            Picker(selection: $sortRaw) {
                ForEach(AlbumSortOption.allCases, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Label(tr("Sort", "Sortieren"), systemImage: "arrow.up.arrow.down")
            }

            if sortOption != .alphabetical {
                Picker(selection: $directionRaw) {
                    ForEach(SortDirection.allCases, id: \.rawValue) { dir in
                        Text(dir.label).tag(dir.rawValue)
                    }
                } label: {
                    Label(tr("Direction", "Richtung"), systemImage: "arrow.up.and.down")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(accentColor)
        }
    }

    private func loadDetail() async {
        isLoading = true
        do {
            detail = try await SubsonicAPIService.shared.getArtist(id: artist.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func fetchAllSongs(from albums: [Album]) async -> [Song] {
        let indexed = Array(albums.enumerated())
        return await withTaskGroup(of: (Int, [Song]).self) { group in
            for (i, album) in indexed {
                group.addTask {
                    guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                          let songs = detail.song else { return (i, []) }
                    return (i, songs)
                }
            }
            var results: [(Int, [Song])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        }
    }
}
