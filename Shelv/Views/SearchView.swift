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
                                        Button {
                                            Task {
                                                guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                                                      let songs = detail.song, !songs.isEmpty else { return }
                                                await MainActor.run { player.addToQueue(songs) }
                                            }
                                        } label: { Image(systemName: "text.badge.plus") }
                                        .tint(accentColor)
                                        Button {
                                            Task {
                                                guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                                                      let songs = detail.song, !songs.isEmpty else { return }
                                                await MainActor.run { player.addPlayNext(songs) }
                                            }
                                        } label: { Image(systemName: "text.insert") }
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
                                            Button {
                                                Task {
                                                    guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                                                          let songs = detail.song, !songs.isEmpty else { return }
                                                    let ids = songs.map(\.id)
                                                    await MainActor.run {
                                                        playlistSongIds = ids
                                                        showAddToPlaylist = true
                                                    }
                                                }
                                            } label: { Image(systemName: "music.note.list") }
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
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            player.addToQueue(song)
                                        } label: {
                                            Image(systemName: "text.badge.plus")
                                        }
                                        .tint(accentColor)
                                        Button {
                                            player.addPlayNext(song)
                                        } label: {
                                            Image(systemName: "text.insert")
                                        }
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
            .sheet(isPresented: $showAddToPlaylist) {
                AddToPlaylistSheet(songIds: playlistSongIds)
                    .environmentObject(libraryStore)
                    .tint(accentColor)
            }
        }
    }

    private func performSearch(query: String) async {
        isSearching = true
        do {
            result = try await SubsonicAPIService.shared.search(query: query)
        } catch {}
        isSearching = false
    }
}
