import SwiftUI

struct SearchView: View {
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @EnvironmentObject var serverStore: ServerStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false
    @ObservedObject var downloadStore = DownloadStore.shared

    @State private var query = ""
    @State private var result: SearchResult?
    @State private var lyricsResults: [LyricsSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var currentToast: ShelveToast?

    private var hasResults: Bool {
        !(result?.artist ?? []).isEmpty ||
        !(result?.album ?? []).isEmpty ||
        !(result?.song ?? []).isEmpty ||
        !lyricsResults.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(tr(
                            "Search for artists, albums or songs",
                            "Künstler, Alben oder Titel suchen"
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasResults {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        if let artists = result?.artist.map({ $0.filter { ($0.albumCount ?? 0) > 0 } }), !artists.isEmpty {
                            Section(tr("Artists", "Künstler")) {
                                ForEach(artists) { artist in
                                    NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                        HStack(spacing: 12) {
                                            AlbumArtView(coverArtId: artist.coverArt, size: 100, isCircle: true)
                                                .frame(width: 44, height: 44)
                                            Text(artist.name)
                                                .font(.body)
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button { queueArtist(artist) } label: { Image(systemName: "text.badge.plus") }
                                            .tint(accentColor)
                                        Button { playNextArtist(artist) } label: { Image(systemName: "text.insert") }
                                            .tint(.orange)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        if enableFavorites && !offlineMode.isOffline {
                                            Button {
                                                Task { await libraryStore.toggleStarArtist(artist) }
                                            } label: {
                                                Image(systemName: libraryStore.isArtistStarred(artist) ? "heart.slash" : "heart.fill")
                                            }
                                            .tint(.pink)
                                        }
                                    }
                                }
                            }
                        }

                        if let albums = result?.album, !albums.isEmpty {
                            Section(tr("Albums", "Alben")) {
                                ForEach(albums) { album in
                                    NavigationLink(destination: AlbumDetailView(album: album)) {
                                        HStack(spacing: 12) {
                                            AlbumArtView(coverArtId: album.coverArt, size: 100, cornerRadius: 8)
                                                .frame(width: 44, height: 44)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(album.name).font(.body)
                                                if let artist = album.artist {
                                                    Text(artist)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button { queueAlbum(album) } label: { Image(systemName: "text.badge.plus") }
                                            .tint(accentColor)
                                        Button { playNextAlbum(album) } label: { Image(systemName: "text.insert") }
                                            .tint(.orange)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        if !offlineMode.isOffline {
                                            if enableFavorites {
                                                Button {
                                                    Task { await libraryStore.toggleStarAlbum(album) }
                                                } label: {
                                                    let starred = libraryStore.isAlbumStarred(album)
                                                    Image(systemName: starred ? "heart.slash" : "heart.fill")
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
                            }
                        }

                        if let songs = result?.song, !songs.isEmpty {
                            Section(tr("Songs", "Titel")) {
                                ForEach(songs) { song in
                                    Button {
                                        player.playSong(song)
                                    } label: {
                                        HStack(spacing: 12) {
                                            AlbumArtView(coverArtId: song.coverArt, size: 100, cornerRadius: 8)
                                                .frame(width: 44, height: 44)
                                                .overlay {
                                                    NowPlayingOverlay(
                                                        songId: song.id, size: 44,
                                                        cornerRadius: 8, accentColor: accentColor
                                                    )
                                                }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(song.title)
                                                    .font(.body)
                                                    .foregroundStyle(.primary)
                                                if let artist = song.artist {
                                                    Text(artist)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Text(song.durationFormatted)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            player.playSong(song)
                                        } label: { Label(tr("Play", "Abspielen"), systemImage: "play.fill") }
                                        Button {
                                            player.addPlayNext(song)
                                            currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
                                        } label: { Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert") }
                                        Button {
                                            player.addToQueue(song)
                                            currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                                        } label: { Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus") }
                                        if !offlineMode.isOffline && (enableFavorites || enablePlaylists) {
                                            Divider()
                                            if enableFavorites {
                                                Button {
                                                    Task { await libraryStore.toggleStarSong(song) }
                                                } label: {
                                                    Label(
                                                        libraryStore.isSongStarred(song)
                                                            ? tr("Unfavorite", "Aus Favoriten entfernen")
                                                            : tr("Favorite", "Zu Favoriten"),
                                                        systemImage: libraryStore.isSongStarred(song) ? "heart.slash" : "heart"
                                                    )
                                                }
                                            }
                                            if enablePlaylists {
                                                Button {
                                                    playlistSongIds = [song.id]
                                                    showAddToPlaylist = true
                                                } label: {
                                                    Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list")
                                                }
                                            }
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            player.addToQueue(song)
                                            currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                                        } label: { Image(systemName: "text.badge.plus") }
                                        .tint(accentColor)
                                        Button {
                                            player.addPlayNext(song)
                                            currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
                                        } label: { Image(systemName: "text.insert") }
                                        .tint(.orange)
                                        if enableDownloads {
                                            if downloadStore.isDownloaded(songId: song.id) {
                                                Button(role: .destructive) {
                                                    downloadStore.deleteSong(song.id)
                                                } label: { DeleteDownloadIcon() }
                                                .tint(.red)
                                            } else if !offlineMode.isOffline {
                                                Button {
                                                    downloadStore.enqueueSongs([song])
                                                } label: { Image(systemName: "arrow.down.circle") }
                                                .tint(accentColor)
                                            }
                                        }
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        if enableFavorites && !offlineMode.isOffline {
                                            Button {
                                                Task { await libraryStore.toggleStarSong(song) }
                                            } label: {
                                                Image(systemName: libraryStore.isSongStarred(song) ? "heart.slash" : "heart.fill")
                                            }
                                            .tint(.pink)
                                        }
                                        if enablePlaylists && !offlineMode.isOffline {
                                            Button {
                                                playlistSongIds = [song.id]
                                                showAddToPlaylist = true
                                            } label: {
                                                Image(systemName: "music.note.list")
                                            }
                                            .tint(.purple)
                                        }
                                    }
                                }
                            }
                        }
                        if !lyricsResults.isEmpty {
                            Section(tr("Lyrics", "Lyrics")) {
                                ForEach(lyricsResults) { item in
                                    Button {
                                        playLyricsResult(item)
                                    } label: {
                                        HStack(spacing: 12) {
                                            AlbumArtView(coverArtId: item.coverArt, size: 100, cornerRadius: 8)
                                                .frame(width: 44, height: 44)
                                                .overlay {
                                                    NowPlayingOverlay(
                                                        songId: item.songId, size: 44,
                                                        cornerRadius: 8, accentColor: accentColor
                                                    )
                                                }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.songTitle ?? tr("Unknown Song", "Unbekannter Titel"))
                                                    .font(.body)
                                                    .foregroundStyle(item.songTitle != nil ? Color.primary : Color.secondary)
                                                if let artist = item.artistName {
                                                    Text(artist)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Text(item.snippet)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                                    .italic()
                                            }
                                            Spacer()
                                            if let dur = item.duration {
                                                Text(String(format: "%d:%02d", dur / 60, dur % 60))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .monospacedDigit()
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Section {
                            PlayerBottomSpacer(activeHeight: 90, inactiveHeight: 0)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle(tr("Search", "Suchen"))
            .searchable(
                text: $query,
                prompt: tr("Artists, albums, songs...", "Künstler, Alben, Titel...")
            )
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                guard !newValue.isEmpty else {
                    result = nil
                    lyricsResults = []
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    await performSearch(query: newValue)
                }
            }
            .shelveToast($currentToast)
            .alert(tr("Error", "Fehler"), isPresented: $showError, presenting: errorMessage) { _ in
                Button(tr("OK", "OK"), role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
            .sheet(isPresented: $showAddToPlaylist) {
                AddToPlaylistSheet(songIds: playlistSongIds)
                    .environmentObject(libraryStore)
                    .tint(accentColor)
            }
        }
    }

    private func queueArtist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            player.addToQueue(songs)
            currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
        }
    }

    private func playNextArtist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            player.addPlayNext(songs)
            currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
        }
    }

    private func queueAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.addToQueue(songs)
                currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func playNextAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.addPlayNext(songs)
                currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func addAlbumToPlaylist(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                playlistSongIds = songs.map(\.id)
                showAddToPlaylist = true
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func playLyricsResult(_ item: LyricsSearchResult) {
        Task {
            if let song = try? await SubsonicAPIService.shared.getSong(id: item.songId) {
                player.playSong(song)
                // Metadaten in DB nachfüllen, damit künftige Suchen den echten Namen zeigen
                if item.songTitle == nil || item.artistName == nil || item.coverArt == nil || item.duration == nil,
                   let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString {
                    Task.detached(priority: .utility) {
                        await LyricsService.shared.updateMetadata(
                            songId: item.songId, serverId: serverId,
                            title: song.title, artist: song.artist, coverArt: song.coverArt,
                            duration: song.duration
                        )
                    }
                }
            } else {
                // Fallback: mit vorhandenen Daten abspielen
                let song = Song(
                    id: item.songId,
                    title: item.songTitle ?? item.songId,
                    artist: item.artistName, album: nil, albumId: nil,
                    track: nil, duration: nil, coverArt: item.coverArt,
                    year: nil, genre: nil, playCount: nil,
                    starred: nil, suffix: nil, bitRate: nil
                )
                player.playSong(song)
            }
        }
    }

    private func performSearch(query: String) async {
        isSearching = true
        if offlineMode.isOffline {
            await performOfflineSearch(query: query)
            isSearching = false
            return
        }
        do {
            result = try await SubsonicAPIService.shared.search(query: query)
        } catch {
            let isCancelled = error is CancellationError
                || (error as? URLError)?.code == .cancelled
            if isCancelled {
                isSearching = false
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        }
        guard !Task.isCancelled else { isSearching = false; return }
        isSearching = false
        if let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString {
            let results = await LyricsService.shared.searchLyrics(text: query, serverId: serverId)
            lyricsResults = results
            let missing = results.filter { $0.songTitle == nil || $0.duration == nil }
            if !missing.isEmpty {
                for item in missing {
                    guard !Task.isCancelled else { break }
                    guard let song = try? await SubsonicAPIService.shared.getSong(id: item.songId) else { continue }
                    await LyricsService.shared.updateMetadata(
                        songId: item.songId, serverId: serverId,
                        title: song.title, artist: song.artist, coverArt: song.coverArt,
                        duration: song.duration
                    )
                    if let idx = lyricsResults.firstIndex(where: { $0.songId == item.songId }) {
                        lyricsResults[idx] = LyricsSearchResult(
                            songId: item.songId,
                            songTitle: song.title, artistName: song.artist,
                            coverArt: song.coverArt, snippet: item.snippet,
                            duration: song.duration
                        )
                    }
                }
            }
        }
    }

    private func performOfflineSearch(query: String) async {
        guard let sid = serverStore.activeServer?.stableId, !sid.isEmpty else {
            result = SearchResult(artist: [], album: [], song: [])
            lyricsResults = []
            return
        }
        let records = await DownloadDatabase.shared.search(serverId: sid, query: query, limit: 100)
        let songs = records.map { $0.toDownloadedSong().asSong() }
        let q = query.lowercased()
        let matchedAlbums = DownloadStore.shared.albums
            .filter { $0.title.lowercased().contains(q) || $0.artistName.lowercased().contains(q) }
            .map { $0.asAlbum() }
        let matchedArtists = DownloadStore.shared.artists
            .filter { $0.name.lowercased().contains(q) }
            .map { $0.asArtist() }
        result = SearchResult(artist: matchedArtists, album: matchedAlbums, song: songs)
        let lyricsSid = serverStore.activeServer?.id.uuidString ?? sid
        let allLyrics = await LyricsService.shared.searchLyrics(text: query, serverId: lyricsSid)
        let downloadedIds = Set(DownloadStore.shared.songs.map { $0.songId })
        lyricsResults = allLyrics.filter { downloadedIds.contains($0.songId) }
    }
}
