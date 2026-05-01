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
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    private func serverStableId() -> String { serverStore.activeServer?.stableId ?? "" }
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
        case .newest:
            let base = albums.sorted {
                ($0.created ?? .distantPast) < ($1.created ?? .distantPast)
            }
            return direction == .ascending ? base : Array(base.reversed())
        case .year:
            let base = albums.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
            return direction == .ascending ? base : Array(base.reversed())
        }
    }

    var body: some View {
        Group {
            if isGrid {
                gridBody
            } else {
                listBody
            }
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if enableFavorites && !offlineMode.isOffline {
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
                        Text("\(count) \(tr("Albums", "Alben"))")
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
                            Label(tr("Play", "Abspielen"), systemImage: "play.fill")
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
                            Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
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

            if enableDownloads, !isLoading, totalArtistSongs > 0 {
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
                    Text(tr("Albums", "Alben"))
                        .font(.title3).bold()
                        .padding(.horizontal)

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(sortedAlbums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCardView(album: album, showArtist: false, showYear: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
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
                    ForEach(sortedAlbums) { album in
                        NavigationLink(destination: AlbumDetailView(album: album)) {
                            albumListRow(album)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .albumContextMenu(album, showPreview: false)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { queueAlbum(album) } label: { Image(systemName: "text.badge.plus") }
                                .tint(accentColor)
                            Button { playNextAlbum(album) } label: { Image(systemName: "text.insert") }
                                .tint(.orange)
                            albumDownloadSwipeButton(album)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !offlineMode.isOffline {
                                if enableFavorites {
                                    Button {
                                        Task { await libraryStore.toggleStarAlbum(album) }
                                    } label: {
                                        Image(systemName: libraryStore.isAlbumStarred(album) ? "heart.slash" : "heart.fill")
                                    }
                                    .tint(.pink)
                                }
                                if enablePlaylists {
                                    Button { addAlbumToPlaylist(album) } label: { Image(systemName: "music.note.list") }
                                        .tint(.purple)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(tr("Albums", "Alben"))
                            .font(.title3).bold()
                            .textCase(nil)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.leading, 0)
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
                currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
            }
        }
    }

    private func playNextAlbum(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            await MainActor.run {
                player.addPlayNext(songs)
                currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
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

    @ViewBuilder
    private func albumDownloadSwipeButton(_ album: Album) -> some View {
        if enableDownloads {
            let status = downloadStore.albumDownloadStatus(albumId: album.id,
                                                           totalSongs: album.songCount ?? 0)
            switch status {
            case .none, .partial:
                if !offlineMode.isOffline {
                    Button {
                        downloadStore.enqueueAlbum(album)
                    } label: { Image(systemName: "arrow.down.circle") }
                    .tint(accentColor)
                }
            case .complete:
                Button(role: .destructive) {
                    downloadStore.deleteAlbum(album.id)
                } label: { DeleteDownloadIcon() }
                .tint(.red)
            }
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
                let albums = sortedAlbums
                guard !albums.isEmpty else { return }
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
                let albums = sortedAlbums
                guard !albums.isEmpty else { return }
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

            if enablePlaylists && !offlineMode.isOffline {
                Button {
                    let albums = sortedAlbums
                    guard !albums.isEmpty else { return }
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

            Menu {
                Picker(selection: $sortRaw) {
                    ForEach(AlbumSortOption.allCases.filter { !offlineMode.isOffline || !$0.requiresServer }, id: \.rawValue) { option in
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
                Label(tr("Sort", "Sortieren"), systemImage: "arrow.up.arrow.down")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(accentColor)
        }
    }

    private func loadDetail() async {
        isLoading = true
        if offlineMode.isOffline {
            populateFromLocal()
            isLoading = false
            return
        }
        do {
            detail = try await SubsonicAPIService.shared.getArtist(id: artist.id)
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

    private var totalArtistSongs: Int {
        detail?.album?.compactMap(\.songCount).reduce(0, +) ?? 0
    }

    private var downloadedArtistSongs: Int {
        downloadStore.songs.filter { $0.artistName == artist.name }.count
    }

    private var artistDownloadStatus: AlbumDownloadStatus {
        let total = totalArtistSongs
        let done = downloadedArtistSongs
        guard total > 0 else { return .none }
        if done == 0 { return .none }
        if done >= total { return .complete }
        return .partial(downloaded: done, total: total)
    }

    @ViewBuilder
    private func downloadHeaderButtons() -> some View {
        HStack(spacing: 10) {
            switch artistDownloadStatus {
            case .none:
                if !offlineMode.isOffline {
                    Button {
                        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: serverStableId()) }
                        currentToast = ShelveToast(message: tr("Download started", "Download gestartet"))
                    } label: {
                        Label(tr("Download", "Herunterladen"), systemImage: "arrow.down.circle")
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
                        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: serverStableId()) }
                        currentToast = ShelveToast(message: tr("Download started", "Download gestartet"))
                    } label: {
                        Label(tr("Rest (\(tot - done))", "Rest (\(tot - done))"), systemImage: "arrow.down.circle")
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
                    if let match = downloadStore.artists.first(where: { $0.name == artist.name }) {
                        downloadStore.deleteArtist(match.artistId)
                        currentToast = ShelveToast(message: tr("Downloads deleted", "Downloads gelöscht"))
                    }
                } label: {
                    Label(tr("Delete", "Löschen"), systemImage: "arrow.down.circle")
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
                    if let match = downloadStore.artists.first(where: { $0.name == artist.name }) {
                        downloadStore.deleteArtist(match.artistId)
                        currentToast = ShelveToast(message: tr("Downloads deleted", "Downloads gelöscht"))
                    }
                } label: {
                    Label(tr("Delete Downloads", "Downloads löschen"), systemImage: "arrow.down.circle")
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
