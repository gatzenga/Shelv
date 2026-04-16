import SwiftUI

struct SearchView: View {
    @EnvironmentObject var player: AudioPlayerService
    @EnvironmentObject var libraryStore: LibraryStore
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true

    @State private var query = ""
    @State private var result: SearchResult?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var toastMessage = ""
    @State private var showToast = false
    @State private var toastTask: Task<Void, Never>?

    private var hasResults: Bool {
        !(result?.artist ?? []).isEmpty ||
        !(result?.album ?? []).isEmpty ||
        !(result?.song ?? []).isEmpty
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
                        if let artists = result?.artist, !artists.isEmpty {
                            Section(tr("Artists", "Künstler")) {
                                ForEach(artists) { artist in
                                    NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                        HStack(spacing: 12) {
                                            AlbumArtView(coverArtId: artist.coverArt, size: 100, cornerRadius: 8)
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
                                        if enableFavorites {
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
                                            toast(tr("Plays Next", "Wird als nächstes gespielt"))
                                        } label: { Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert") }
                                        Button {
                                            player.addToQueue(song)
                                            toast(tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                                        } label: { Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus") }
                                        if enableFavorites || enablePlaylists {
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
                                            toast(tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                                        } label: { Image(systemName: "text.badge.plus") }
                                        .tint(accentColor)
                                        Button {
                                            player.addPlayNext(song)
                                            toast(tr("Plays Next", "Wird als nächstes gespielt"))
                                        } label: { Image(systemName: "text.insert") }
                                        .tint(.orange)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        if enableFavorites {
                                            Button {
                                                Task { await libraryStore.toggleStarSong(song) }
                                            } label: {
                                                Image(systemName: libraryStore.isSongStarred(song) ? "heart.slash" : "heart.fill")
                                            }
                                            .tint(.pink)
                                        }
                                        if enablePlaylists {
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
                        Section {
                            Color.clear
                                .frame(height: player.currentSong != nil ? 90 : 0)
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
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    await performSearch(query: newValue)
                }
            }
            .overlay(alignment: .top) {
                if showToast {
                    toastBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showToast)
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

    private var toastBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text(toastMessage)
                .font(.subheadline).bold()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(accentColor)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .padding(.top, 8)
        .allowsHitTesting(false)
    }

    private func toast(_ message: String) {
        toastMessage = message
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showToast = true }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { showToast = false }
        }
    }

    private func fetchAlbumSongs(_ album: Album) async throws -> [Song] {
        let detail = try await SubsonicAPIService.shared.getAlbum(id: album.id)
        return detail.song ?? []
    }

    private func queueArtist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            player.addToQueue(songs)
            toast(tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
        }
    }

    private func playNextArtist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            player.addPlayNext(songs)
            toast(tr("Plays Next", "Wird als nächstes gespielt"))
        }
    }

    private func queueAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.addToQueue(songs)
                toast(tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func playNextAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.addPlayNext(songs)
                toast(tr("Plays Next", "Wird als nächstes gespielt"))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func addAlbumToPlaylist(_ album: Album) {
        Task {
            do {
                let songs = try await fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                playlistSongIds = songs.map(\.id)
                showAddToPlaylist = true
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func performSearch(query: String) async {
        isSearching = true
        do {
            result = try await SubsonicAPIService.shared.search(query: query)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isSearching = false
    }
}
