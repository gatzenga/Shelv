import SwiftUI

/// Einheitliche Spalten für alle Cover-Grids: feste 240er-Cover (wie Discover),
/// linksbündig gepackt — nicht zentriert, nicht gestreckt. Auf 1920 pt → 6 Spalten.
let coverGridColumns = Array(repeating: GridItem(.fixed(240), spacing: 40), count: 6)

/// tvOS-Zeilen-Button-Stil: KEIN System-Zoom/-Highlight (das käme von `.card`/`.automatic`),
/// nur ein dezenter Press-Effekt. Den Fokus-Look zeichnet der `rowButton`-Modifier per Akzent-Box.
struct PlainRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Verwandelt eine Zeilen-View (HStack o. ä.) in einen **echten** tvOS-Button — die
/// Select-Taste feuert damit zuverlässig (anders als `.onTapGesture` auf `.focusable()`).
/// Markierung allein über die abgerundete Akzent-Box, kein weißes Highlight, kein Cover-Zoom.
private struct RowButtonModifier: ViewModifier {
    let action: () -> Void
    @FocusState private var focused: Bool
    @AppStorage("themeColor") private var themeColor = "violet"

    func body(content: Content) -> some View {
        Button(action: action) {
            content
                .padding(.vertical, 10)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(focused ? AppTheme.color(for: themeColor).opacity(0.4) : Color.clear))
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainRowButtonStyle())
        .focused($focused)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}

extension View {
    /// Einheitlicher, zuverlässig auslösbarer Zeilen-Button mit Akzent-Box-Fokus.
    func rowButton(action: @escaping () -> Void) -> some View { modifier(RowButtonModifier(action: action)) }

    /// Sanftes Aus-/Einblenden an Ober- und Unterkante — Inhalt reißt nicht hart an der
    /// Tab-Leiste bzw. am unteren Rand ab (Lyrics & Warteschlange im Now-Playing-Panel).
    func edgeFadeMask() -> some View {
        mask(LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.10),
                .init(color: .black, location: 0.90),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        ))
    }
}

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
struct NowPlayingNumber: View {
    let songId: String
    let index: Int
    @ObservedObject private var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColor = "violet"

    var body: some View {
        Group {
            if player.currentSong?.id == songId {
                Image(systemName: "waveform")
                    .font(.body)
                    .foregroundStyle(AppTheme.color(for: themeColor))
                    .symbolEffect(.variableColor.iterative.reversing, isActive: player.isPlaying)
            } else {
                Text("\(index + 1)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, alignment: .trailing)
    }
}

/// Dimm-Overlay + animiertes Lautsprecher-Icon auf dem Cover, wenn dieser Song läuft
/// (wie iOS NowPlayingOverlay). Als `.overlay { }` auf eine CoverArtView legen.
struct NowPlayingOverlay: View {
    let songId: String
    let size: CGFloat
    var cornerRadius: CGFloat = 8
    var isCircle: Bool = false
    @ObservedObject private var player = AudioPlayerService.shared

    var body: some View {
        if player.currentSong?.id == songId {
            ZStack {
                Color.black.opacity(0.4)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: player.isPlaying)
            }
            .frame(width: size, height: size)
            .clipShape(isCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius)))
        }
    }
}

/// Destruktiver Listen-Button mit sattem Rot, das auch im Fokus rot bleibt.
/// `role(.destructive)` / `.foregroundStyle(.red)` verblassen auf tvOS im Fokus (heller
/// System-Platter). Mit `.buttonStyle(.plain)` bleibt die rote Schrift erhalten; der Fokus
/// wird über einen roten Zeilen-Hintergrund angezeigt.
struct DestructiveButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .foregroundStyle(.red)
            .bold()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .listRowBackground(focused ? Color.red.opacity(0.22) : nil)
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

/// Song-Zeile für die Zwei-Spalten-Detailansichten (Album/Playlist) im LazyVStack.
/// Eigener abgerundeter Fokus-Highlight in Akzentfarbe — das System-List-Highlight
/// würde an der schmalen Spaltenkante sonst hart abgeschnitten.
struct DetailSongRow: View {
    let song: Song
    let number: Int
    var showArtwork: Bool = false
    /// Rang-Zahl links vom Cover (Playlists/Recap). nil = keine Zahl (z.B. Queue).
    var rank: Int? = nil
    /// Recap: erste drei Ränge fett in Akzentfarbe hervorheben.
    var rankAccent: Bool = false
    /// Recap: Playcount des Songs (Periodenwert) anzeigen. nil = kein Badge.
    var playCount: Int? = nil
    let onPlay: () -> Void
    @AppStorage("themeColor") private var themeColor = "violet"

    var body: some View {
        HStack(spacing: 20) {
            if let rank {
                let isTop3 = rankAccent && rank <= 3
                Text("\(rank)")
                    .font(isTop3 ? .body.bold() : .body)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(isTop3 ? AnyShapeStyle(AppTheme.color(for: themeColor)) : AnyShapeStyle(.secondary))
                    .frame(width: 50, alignment: .trailing)
            }
            if showArtwork {
                CoverArtView(url: song.coverURL(200), size: 56, cornerRadius: 6)
                    .overlay { NowPlayingOverlay(songId: song.id, size: 56, cornerRadius: 6) }
            } else {
                NowPlayingNumber(songId: song.id, index: number)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                if let artist = song.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let playCount {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.caption2)
                    Text("\(playCount)").font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
            if let d = song.duration {
                Text(formatDuration(d)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .rowButton(action: onPlay)
        .songContextMenu(song)
    }
}

/// Album-Zeile (Listenansicht) im einheitlichen borderless-Akzent-Fokus-Stil.
struct AlbumListRow: View {
    let album: Album
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            CoverArtView(url: album.coverURL(200), size: 80, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name).lineLimit(1)
                if let artist = album.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .rowButton(action: onSelect)
        .albumContextMenu(album)
    }
}

/// Künstler-Zeile (Listenansicht) im einheitlichen borderless-Akzent-Fokus-Stil.
struct ArtistListRow: View {
    let artist: Artist
    let albumCount: Int
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            CoverArtView(url: artist.coverURL(200), size: 80, isCircle: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name).lineLimit(1)
                if albumCount > 0 {
                    Text("\(albumCount) \(String(localized: "albums"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .rowButton(action: onSelect)
        .artistContextMenu(artist)
    }
}

/// Playlist-Zeile (Listenansicht) im einheitlichen borderless-Akzent-Fokus-Stil.
struct PlaylistListRow: View {
    let playlist: Playlist
    let onSelect: () -> Void
    @ObservedObject private var pins = PinnedPlaylistStore.shared

    var body: some View {
        HStack(spacing: 20) {
            CoverArtView(url: playlist.coverURL(200), size: 80, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if pins.isPinned(playlist.id) {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(playlist.name).lineLimit(1)
                }
                if let count = playlist.songCount {
                    Text("\(count) \(String(localized: "songs"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .rowButton(action: onSelect)
        .playlistContextMenu(playlist)
    }
}

/// Text-Link (z. B. Künstler/Album): keine Box, der Text färbt sich bei Fokus in die Akzentfarbe.
struct AccentTextLink<Destination: View>: View {
    let text: String
    let font: Font
    @ViewBuilder let destination: () -> Destination
    @FocusState private var focused: Bool
    @AppStorage("themeColor") private var themeColor = "violet"

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            Text(text)
                .font(font)
                .lineLimit(1)
                .foregroundStyle(focused ? AppTheme.color(for: themeColor) : Color.secondary)
        }
        .buttonStyle(.borderless)
        .focused($focused)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Echtes Künstler-Objekt aus der Library (per Name) — damit Cover/Navigation stimmen —,
/// sonst aus den vorhandenen Metadaten konstruiert.
func resolvedLibraryArtist(name: String, id: String?) -> Artist {
    if let found = LibraryStore.shared.artists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
        return found
    }
    return Artist(id: id ?? "", name: name)
}
