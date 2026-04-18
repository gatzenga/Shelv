import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var recapStore: RecapStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var visiblePlaylists: [Playlist] {
        libraryStore.playlists.filter { !recapStore.recapPlaylistIds.contains($0.id) }
    }

    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var showDeleteConfirm = false
    @State private var playlistToDelete: Playlist?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var currentToast: ShelveToast?

    var body: some View {
        NavigationStack {
            Group {
                if libraryStore.isLoadingPlaylists && libraryStore.playlists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visiblePlaylists.isEmpty {
                    ContentUnavailableView(
                        tr("No Playlists", "Keine Playlists"),
                        systemImage: "music.note.list",
                        description: Text(tr(
                            "Create a playlist to get started.",
                            "Erstelle eine Playlist, um loszulegen."
                        ))
                    )
                } else {
                    List {
                        Section {
                            ForEach(visiblePlaylists) { playlist in
                                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                                    playlistRow(playlist)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        playlistToDelete = playlist
                                        showDeleteConfirm = true
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    Button {
                                        Task {
                                            if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                                               let songs = loaded.songs, !songs.isEmpty {
                                                await MainActor.run {
                                                    player.addToQueue(songs)
                                                    currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                                                }
                                            }
                                        }
                                    } label: { Image(systemName: "text.badge.plus") }
                                    .tint(accentColor)
                                    Button {
                                        Task {
                                            if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                                               let songs = loaded.songs, !songs.isEmpty {
                                                await MainActor.run {
                                                    player.addPlayNext(songs)
                                                    currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
                                                }
                                            }
                                        }
                                    } label: { Image(systemName: "text.insert") }
                                    .tint(.orange)
                                }
                            }
                        }
                        .listSectionSeparator(.hidden, edges: .top)

                        PlayerBottomSpacer()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle(tr("Playlists", "Playlists"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newPlaylistName = ""
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task(id: libraryStore.reloadID) {
                await libraryStore.loadPlaylists()
            }
            .refreshable {
                await libraryStore.loadPlaylists()
            }
            .alert(
                tr("Delete Playlist?", "Playlist löschen?"),
                isPresented: $showDeleteConfirm,
                presenting: playlistToDelete
            ) { playlist in
                Button(tr("Delete", "Löschen"), role: .destructive) {
                    Task { await libraryStore.deletePlaylist(playlist) }
                }
                Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { playlist in
                Text("\"\(playlist.name)\"")
            }
            .onChange(of: libraryStore.errorMessage) { _, msg in
                if let msg {
                    errorMessage = msg
                    showError = true
                    libraryStore.errorMessage = nil
                }
            }
            .alert(tr("Error", "Fehler"), isPresented: $showError, presenting: errorMessage) { _ in
                Button(tr("OK", "OK"), role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
            .shelveToast($currentToast)
            .sheet(isPresented: $showCreateSheet) {
                createPlaylistSheet
            }
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: playlist.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let count = playlist.songCount {
                    Text("\(count) \(tr("Songs", "Titel"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var createPlaylistSheet: some View {
        NavigationStack {
            Form {
                Section(tr("Name", "Name")) {
                    TextField(tr("My Playlist", "Meine Playlist"), text: $newPlaylistName)
                        .focused($nameFieldFocused)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(tr("New Playlist", "Neue Playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    nameFieldFocused = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("Cancel", "Abbrechen"), role: .cancel) {
                        showCreateSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("Create", "Erstellen")) {
                        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        showCreateSheet = false
                        Task { await libraryStore.createPlaylist(name: name) }
                    }
                    .bold()
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .tint(accentColor)
        }
        .presentationDetents([.medium])
        .presentationCornerRadius(24)
    }
}
