import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var store = LibraryStore.shared
    @ObservedObject var recap = RecapStore.shared
    @ObservedObject var pins = PinnedPlaylistStore.shared
    @AppStorage("playlistSortOption") private var sortRaw = "alphabetical"
    @AppStorage("playlistSortDirection") private var dirRaw = "ascending"
    @AppStorage("playlistViewIsGrid") private var isGrid = true

    @State private var showCreate = false
    @State private var path = NavigationPath()

    private var sort: PlaylistSortOption { PlaylistSortOption(rawValue: sortRaw) ?? .alphabetical }
    private var dir: SortDirection { SortDirection(rawValue: dirRaw) ?? .ascending }

    /// Recap-Playlists raus, dann sortiert; angepinnte immer oben (nach pinRank).
    private var displayPlaylists: [Playlist] {
        var base = store.playlists.filter { !recap.recapPlaylistIds.contains($0.id) }
        switch sort {
        case .alphabetical: base.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastModified: base.sort { ($0.changed ?? .distantPast) < ($1.changed ?? .distantPast) }
        case .dateCreated:  base.sort { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        }
        if dir == .descending { base.reverse() }
        let pinned = base.filter { pins.isPinned($0.id) }
            .sorted { (pins.pinRank($0.id) ?? 0) < (pins.pinRank($1.id) ?? 0) }
        let rest = base.filter { !pins.isPinned($0.id) }
        return pinned + rest
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack(spacing: 24) {
                    Menu {
                        ForEach(PlaylistSortOption.allCases, id: \.rawValue) { opt in
                            Button { sortRaw = opt.rawValue } label: {
                                if sort == opt { Label(opt.label, systemImage: "checkmark") } else { Text(opt.label) }
                            }
                        }
                    } label: {
                        Label(sort.label, systemImage: "arrow.up.arrow.down")
                    }
                    Button { dirRaw = dir == .ascending ? "descending" : "ascending" } label: {
                        Image(systemName: dir.icon)
                    }
                    Button { isGrid.toggle() } label: {
                        Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                    }
                    Spacer()
                    Button { showCreate = true } label: {
                        Label(String(localized: "new_playlist_2"), systemImage: "plus")
                    }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 50)
                .padding(.top, 40)
                .padding(.bottom, 16)
                .focusSection()

                Group {
                    if displayPlaylists.isEmpty && store.isLoadingPlaylists {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if displayPlaylists.isEmpty {
                        ContentUnavailableView(String(localized: "no_playlists_2"), systemImage: "music.note.list")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isGrid {
                        gridBody
                    } else {
                        listBody
                    }
                }
                .focusSection()
            }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .task(id: store.reloadID) { await store.loadPlaylists() }
            .sheet(isPresented: $showCreate) {
                PlaylistEditSheet(title: String(localized: "new_playlist_2"),
                                  initialName: "", initialComment: nil, showComment: false) { name, _ in
                    Task { await store.createPlaylist(name: name) }
                }
            }
        }
    }

    private var gridBody: some View {
        ScrollView {
            LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                ForEach(displayPlaylists) { PlaylistCard(playlist: $0) }
            }
            .padding(.horizontal, 50)
            .padding(.top, 30)
            .padding(.bottom, 50)
        }
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(displayPlaylists) { playlist in
                    PlaylistListRow(playlist: playlist) { path.append(playlist) }
                }
            }
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var size: CGFloat = 240
    /// Gesetzt bei Recap-Playlists → Periodentitel statt „Recap" + Periode-Detailansicht.
    var recapPeriod: RecapPeriod? = nil
    @ObservedObject private var pins = PinnedPlaylistStore.shared

    private var displayName: String { recapPeriod?.playlistName ?? playlist.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            NavigationLink {
                PlaylistDetailView(playlist: playlist, recapPeriod: recapPeriod)
            } label: {
                CoverArtView(url: playlist.coverURL(500), size: size, cornerRadius: 8)
            }
            .buttonStyle(.card)
            .playlistContextMenu(playlist)

            HStack(spacing: 8) {
                if pins.isPinned(playlist.id) {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
                Text(displayName).lineLimit(1).font(.callout)
            }
            if let count = playlist.songCount {
                Text("\(count) \(String(localized: "songs"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size)
    }
}

/// Playlist-Seite im Zweispalter (wie das Album): links Cover + Aktionen (zentriert),
/// rechts die scrollende Songliste mit eigenem Fokus-Highlight.
struct PlaylistDetailView: View {
    let playlist: Playlist
    /// Gesetzt für Recap-Playlists → Periodentitel + Periode-Playcounts + Top-3 in Akzentfarbe.
    var recapPeriod: RecapPeriod? = nil
    private let player = AudioPlayerService.shared
    @ObservedObject private var store = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var songs: [Song] = []
    @State private var recapCounts: [String: Int] = [:]
    @State private var showRename = false
    @State private var showDeleteConfirm = false

    private var isRecap: Bool { recapPeriod != nil }

    /// Aktueller Stand (Name/Comment nach Umbenennen) aus dem Store, sonst das übergebene Objekt.
    private var current: Playlist { store.playlists.first { $0.id == playlist.id } ?? playlist }

    /// Recap zeigt den Periodentitel (wie iOS), normale Playlists ihren Namen.
    private var displayName: String { recapPeriod?.playlistName ?? current.name }

    var body: some View {
        HStack(alignment: .center, spacing: 60) {
            leftColumn.frame(width: 300).focusSection()
            trackList.frame(maxHeight: .infinity).focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 60)
        .toolbar(.hidden, for: .tabBar)
        .task {
            songs = await LibraryStore.shared.playlistSongs(playlist)
            // Recap: Periode-Playcounts wie iOS (im Demo liefert topSongs die Recap-Counts).
            if let p = recapPeriod {
                let sid = SubsonicAPIService.shared.activeServer?.stableId ?? ""
                let counts = await PlayLogService.shared.topSongs(
                    serverId: sid, from: p.start, to: p.end, limit: p.type.songLimit)
                recapCounts = Dictionary(counts.map { ($0.songId, $0.count) }, uniquingKeysWith: { a, _ in a })
            }
        }
        .sheet(isPresented: $showRename) {
            PlaylistEditSheet(title: String(localized: "rename"),
                              initialName: current.name, initialComment: current.comment, showComment: true) { name, comment in
                Task { await store.renamePlaylist(playlist, name: name, comment: comment) }
            }
        }
        .confirmationDialog(String(localized: "delete_playlist"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(String(localized: "delete_playlist"), role: .destructive) {
                Task { await store.deletePlaylist(playlist); dismiss() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            CoverArtView(url: current.coverURL(600), size: 300, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 6) {
                Text(displayName).font(.title3).bold().lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let comment = current.comment, !comment.isEmpty {
                    Text(comment).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if let count = current.songCount {
                    Text("\(count) \(String(localized: "songs"))")
                        .font(.body).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 12) {
                actionButton(String(localized: "play"), "play.fill") { player.play(songs: songs, startIndex: 0) }
                actionButton(String(localized: "shuffle"), "shuffle") { player.playShuffled(songs: songs) }
                HStack(spacing: 12) {
                    iconButton("text.line.first.and.arrowtriangle.forward") { player.addPlayNext(songs) }
                    iconButton("text.append") { player.addToQueue(songs) }
                    Menu {
                        Button { showRename = true } label: {
                            Label(String(localized: "rename"), systemImage: "pencil")
                        }
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Label(String(localized: "delete_playlist"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .disabled(songs.isEmpty)
        }
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func iconButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    DetailSongRow(song: song, number: index, showArtwork: true,
                                  rank: index + 1, rankAccent: isRecap,
                                  playCount: isRecap ? (recapCounts[song.id] ?? 0) : nil) {
                        player.play(songs: songs, startIndex: index)
                    }
                }
            }
            .padding(.vertical, 30)
        }
        .scrollIndicators(.hidden)
    }
}

/// Sheet zum Erstellen oder Umbenennen einer Playlist (Name, optional Kommentar).
struct PlaylistEditSheet: View {
    let title: String
    let showComment: Bool
    let onSave: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var comment: String

    init(title: String, initialName: String, initialComment: String?, showComment: Bool,
         onSave: @escaping (String, String?) -> Void) {
        self.title = title
        self.showComment = showComment
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _comment = State(initialValue: initialComment ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 30) {
                TextField(String(localized: "playlist_name"), text: $name)
                if showComment {
                    TextField(String(localized: "comment"), text: $comment)
                }
                HStack(spacing: 30) {
                    Button(String(localized: "cancel"), role: .cancel) { dismiss() }
                    Button(String(localized: "done")) {
                        let c = comment.trimmingCharacters(in: .whitespaces)
                        onSave(trimmedName, showComment ? (c.isEmpty ? nil : c) : nil)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
                Spacer()
            }
            .padding(80)
            .navigationTitle(title)
        }
    }
}
