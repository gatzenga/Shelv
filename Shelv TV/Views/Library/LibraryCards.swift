import SwiftUI

/// Einheitliche Spalten für alle Cover-Grids: feste 240er-Cover (wie Discover),
/// linksbündig gepackt — nicht zentriert, nicht gestreckt. Auf 1920 pt → 6 Spalten.
let coverGridColumns = Array(repeating: GridItem(.fixed(240), spacing: 40), count: 6)

/// Album-Karte: das Cover hebt sich beim Fokus als Ganzes (nativer `.card`-Lift),
/// Titel/Künstler stehen mit genug Abstand darunter — keine umschließende Box.
struct AlbumCard: View {
    let album: Album
    var size: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            NavigationLink {
                AlbumDetailView(album: album)
            } label: {
                CoverArtView(url: album.coverURL(500), size: size, cornerRadius: 8)
            }
            .buttonStyle(.card)
            .albumContextMenu(album)

            Text(album.name).lineLimit(1).font(.callout)
            if let artist = album.artist {
                Text(artist).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size)
    }
}

/// Künstler-Karte: rundes Bild + Name. Das runde Bild zoomt als Ganzes beim Fokus
/// (deutlich, mit Schatten) — ein `.card`-Rechteck würde hier eine Box um den Kreis legen.
struct ArtistCard: View {
    let artist: Artist
    var size: CGFloat = 240

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            NavigationLink {
                ArtistDetailView(artist: artist)
            } label: {
                CoverArtView(url: artist.coverURL(500), size: size, isCircle: true)
                    .scaleEffect(focused ? 1.12 : 1.0)
                    .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 12)
                    .animation(.easeOut(duration: 0.18), value: focused)
            }
            .buttonStyle(.borderless)
            .focused($focused)
            .artistContextMenu(artist)

            Text(artist.name).lineLimit(1).font(.callout)
                .foregroundStyle(focused ? .primary : .secondary)
        }
        .frame(width: size)
    }
}

/// Native Song-Zeile für `List` — in einer `List` liefert tvOS den Fokus-Highlight
/// automatisch. `showArtwork`: Cover-Thumbnail (Suche/Favoriten/Playlist) oder
/// Tracknummer (Albumansicht, wo alle Songs dasselbe Cover hätten).
struct SongRow: View {
    let song: Song
    let index: Int
    var showArtwork: Bool = true
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 20) {
                if showArtwork {
                    CoverArtView(url: song.coverURL(200), size: 64, cornerRadius: 6)
                } else {
                    NowPlayingNumber(songId: song.id, index: index)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).lineLimit(1)
                    if let artist = song.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let d = song.duration {
                    Text(formatDuration(d)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .padding(.trailing, 16)
                }
            }
        }
        .songContextMenu(song)
    }
}

/// Tracknummer, die zum Waveform-Symbol (Akzentfarbe) wird, wenn der Song gerade läuft.
/// Isoliert, beobachtet nur den Player-Songwechsel.
private struct NowPlayingNumber: View {
    let songId: String
    let index: Int
    @ObservedObject private var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColor = "violet"

    var body: some View {
        Group {
            if player.currentSong?.id == songId {
                Image(systemName: "waveform")
                    .foregroundStyle(AppTheme.color(for: themeColor))
            } else {
                Text("\(index + 1)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, alignment: .trailing)
    }
}

func formatDuration(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

// MARK: - Kontextmenüs (Long-Press auf der Remote)
//
// Zentral definiert, damit jede Card/Row dieselben Aktionen bekommt. Aktionen laufen
// über den geteilten AudioPlayerService; Favorit-Status/-Toggle über den tvOS-LibraryStore.

private struct SongContextMenuModifier: ViewModifier {
    let song: Song
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @ObservedObject private var library = LibraryStore.shared
    @State private var showAddToPlaylist = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                let player = AudioPlayerService.shared
                Button { player.addPlayNext(song) } label: {
                    Label(String(localized: "play_next"), systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { player.addToQueue(song) } label: {
                    Label(String(localized: "add_to_queue"), systemImage: "text.append")
                }
                if enableFavorites {
                    let starred = library.isSongStarred(song)
                    Button { Task { await library.toggleStarSong(song) } } label: {
                        Label(starred ? String(localized: "unfavorite") : String(localized: "favorite"),
                              systemImage: starred ? "heart.fill" : "heart")
                    }
                }
                if enablePlaylists {
                    Button { showAddToPlaylist = true } label: {
                        Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showAddToPlaylist) { AddToPlaylistView(songIds: [song.id]) }
    }
}

private struct AlbumContextMenuModifier: ViewModifier {
    let album: Album
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @ObservedObject private var library = LibraryStore.shared
    @State private var addSongIds: [String] = []
    @State private var showAddToPlaylist = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                let player = AudioPlayerService.shared
                Button { Task { let s = await library.albumSongs(album); player.play(songs: s, startIndex: 0) } } label: {
                    Label(String(localized: "play"), systemImage: "play.fill")
                }
                Button { Task { let s = await library.albumSongs(album); player.playShuffled(songs: s) } } label: {
                    Label(String(localized: "shuffle"), systemImage: "shuffle")
                }
                Button { Task { let s = await library.albumSongs(album); player.addPlayNext(s) } } label: {
                    Label(String(localized: "play_next"), systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { Task { let s = await library.albumSongs(album); player.addToQueue(s) } } label: {
                    Label(String(localized: "add_to_queue"), systemImage: "text.append")
                }
                if enableFavorites {
                    let starred = library.isAlbumStarred(album)
                    Button { Task { await library.toggleStarAlbum(album) } } label: {
                        Label(starred ? String(localized: "unfavorite") : String(localized: "favorite"),
                              systemImage: starred ? "heart.fill" : "heart")
                    }
                }
                if enablePlaylists {
                    Button {
                        Task { addSongIds = (await library.albumSongs(album)).map(\.id); showAddToPlaylist = true }
                    } label: {
                        Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showAddToPlaylist) { AddToPlaylistView(songIds: addSongIds) }
    }
}

/// Sheet zum Hinzufügen von Songs zu einer bestehenden oder neuen Playlist.
struct AddToPlaylistView: View {
    let songIds: [String]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var recap = RecapStore.shared
    @State private var showCreate = false

    private var playlists: [Playlist] {
        store.playlists.filter { !recap.recapPlaylistIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Button { showCreate = true } label: {
                    Label(String(localized: "new_playlist_2"), systemImage: "plus")
                }
                ForEach(playlists) { pl in
                    Button {
                        Task { await store.addSongs(songIds, toPlaylist: pl.id); dismiss() }
                    } label: {
                        HStack(spacing: 20) {
                            CoverArtView(url: pl.coverURL(200), size: 60, cornerRadius: 6)
                            Text(pl.name).lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(String(localized: "add_to_playlist_2"))
            .task { await store.loadPlaylists() }
            .sheet(isPresented: $showCreate) {
                PlaylistEditSheet(title: String(localized: "new_playlist_2"),
                                  initialName: "", initialComment: nil, showComment: false) { name, _ in
                    Task { await store.createPlaylist(name: name, songIds: songIds); dismiss() }
                }
            }
        }
    }
}

private struct ArtistContextMenuModifier: ViewModifier {
    let artist: Artist
    @AppStorage("enableFavorites") private var enableFavorites = true
    @ObservedObject private var library = LibraryStore.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            let player = AudioPlayerService.shared
            Button { Task { let s = await library.artistSongs(artist); player.play(songs: s, startIndex: 0) } } label: {
                Label(String(localized: "play"), systemImage: "play.fill")
            }
            Button { Task { let s = await library.artistSongs(artist); player.playShuffled(songs: s) } } label: {
                Label(String(localized: "shuffle"), systemImage: "shuffle")
            }
            if enableFavorites {
                let starred = library.isArtistStarred(artist)
                Button { Task { await library.toggleStarArtist(artist) } } label: {
                    Label(starred ? String(localized: "unfavorite") : String(localized: "favorite"),
                          systemImage: starred ? "heart.fill" : "heart")
                }
            }
        }
    }
}

private struct PlaylistContextMenuModifier: ViewModifier {
    let playlist: Playlist
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var pins = PinnedPlaylistStore.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            let player = AudioPlayerService.shared
            Button { Task { let s = await library.playlistSongs(playlist); player.play(songs: s, startIndex: 0) } } label: {
                Label(String(localized: "play"), systemImage: "play.fill")
            }
            Button { Task { let s = await library.playlistSongs(playlist); player.playShuffled(songs: s) } } label: {
                Label(String(localized: "shuffle"), systemImage: "shuffle")
            }
            Button { Task { let s = await library.playlistSongs(playlist); player.addPlayNext(s) } } label: {
                Label(String(localized: "play_next"), systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { Task { let s = await library.playlistSongs(playlist); player.addToQueue(s) } } label: {
                Label(String(localized: "add_to_queue"), systemImage: "text.append")
            }
            let pinned = pins.isPinned(playlist.id)
            Button { pins.togglePin(playlist.id) } label: {
                Label(pinned ? String(localized: "unpin") : String(localized: "pin"),
                      systemImage: pinned ? "pin.slash" : "pin")
            }
        }
    }
}

extension View {
    func songContextMenu(_ song: Song) -> some View { modifier(SongContextMenuModifier(song: song)) }
    func albumContextMenu(_ album: Album) -> some View { modifier(AlbumContextMenuModifier(album: album)) }
    func artistContextMenu(_ artist: Artist) -> some View { modifier(ArtistContextMenuModifier(artist: artist)) }
    func playlistContextMenu(_ playlist: Playlist) -> some View { modifier(PlaylistContextMenuModifier(playlist: playlist)) }
}
