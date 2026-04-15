import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist

    @EnvironmentObject var player: AudioPlayerService
    @EnvironmentObject var libraryStore: LibraryStore
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true

    @State private var songs: [Song] = []
    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @State private var isLoading = true
    @State private var isEditMode = false
    @State private var showRenameAlert = false
    @State private var newName = ""
    @State private var showDeleteConfirm = false
    @State private var toastMessage = ""
    @State private var showToast = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                headerView
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                }
            } else if songs.isEmpty {
                Section {
                    Text(tr("No songs in this playlist.", "Keine Titel in dieser Playlist."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            player.play(songs: songs, startIndex: index)
                        } label: {
                            HStack(spacing: 14) {
                                if isEditMode {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                } else {
                                    Text("\(index + 1)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                }
                                AlbumArtView(coverArtId: song.coverArt, size: 100, cornerRadius: 6)
                                    .frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let artist = song.artist {
                                        Text(artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(song.durationFormatted)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await removeSong(at: index) }
                            } label: {
                                Image(systemName: "trash")
                            }

                            Button {
                                player.addToQueue(song)
                                toast(tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                            } label: {
                                Image(systemName: "text.badge.plus")
                            }
                            .tint(accentColor)

                            Button {
                                player.addPlayNext(song)
                                toast(tr("Plays Next", "Wird als nächstes gespielt"))
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
                    .onMove { from, to in
                        songs.move(fromOffsets: from, toOffset: to)
                        Task { await syncOrder() }
                    }
                    .onDelete { offsets in
                        Task { await removeSongs(at: offsets) }
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
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .environment(\.editMode, .constant(isEditMode ? .active : .inactive))
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isEditMode.toggle()
                    } label: {
                        Label(
                            isEditMode ? tr("Done", "Fertig") : tr("Reorder / Delete", "Sortieren / Löschen"),
                            systemImage: isEditMode ? "checkmark" : "pencil"
                        )
                    }

                    Button {
                        newName = playlist.name
                        showRenameAlert = true
                    } label: {
                        Label(tr("Rename", "Umbenennen"), systemImage: "pencil.line")
                    }

                    Divider()

                    Button {
                        if !songs.isEmpty { player.play(songs: songs, startIndex: 0) }
                    } label: {
                        Label(tr("Play", "Abspielen"), systemImage: "play.fill")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        if !songs.isEmpty { player.playShuffled(songs: songs) }
                    } label: {
                        Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        if !songs.isEmpty {
                            player.addPlayNext(songs)
                            toast(tr("Plays Next", "Wird als nächstes gespielt"))
                        }
                    } label: {
                        Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
                    }
                    .disabled(songs.isEmpty)

                    Button {
                        if !songs.isEmpty {
                            player.addToQueue(songs)
                            toast(tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                        }
                    } label: {
                        Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
                    }
                    .disabled(songs.isEmpty)

                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(tr("Delete Playlist", "Playlist löschen"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .symbolRenderingMode(.hierarchical)
                }
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
        .alert(tr("Rename Playlist", "Playlist umbenennen"), isPresented: $showRenameAlert) {
            TextField(playlist.name, text: $newName)
            Button(tr("Save", "Speichern")) {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await libraryStore.renamePlaylist(playlist, newName: name) }
            }
            .bold()
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        }
        .alert(tr("Delete Playlist?", "Playlist löschen?"), isPresented: $showDeleteConfirm) {
            Button(tr("Delete", "Löschen"), role: .destructive) {
                Task {
                    await libraryStore.deletePlaylist(playlist)
                    dismiss()
                }
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text("\"\(playlist.name)\"")
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(songIds: playlistSongIds)
                .environmentObject(libraryStore)
                .tint(accentColor)
        }
        .task {
            await loadSongs()
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            AlbumArtView(coverArtId: playlist.coverArt, size: 600, cornerRadius: 16)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            VStack(spacing: 4) {
                Text(playlist.name)
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                if let comment = playlist.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let count = playlist.songCount {
                    Text("\(count) \(tr("Songs", "Titel"))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 14) {
                Button {
                    if !songs.isEmpty { player.play(songs: songs, startIndex: 0) }
                } label: {
                    Label(tr("Play", "Abspielen"), systemImage: "play.fill")
                        .font(.body).bold()
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(songs.isEmpty)

                Button {
                    if !songs.isEmpty { player.playShuffled(songs: songs) }
                } label: {
                    Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
                        .font(.body).bold()
                        .foregroundStyle(accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(songs.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 16)
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
    }

    private func toast(_ message: String) {
        toastMessage = message
        withAnimation { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { showToast = false }
        }
    }

    private func loadSongs() async {
        isLoading = true
        if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id) {
            songs = loaded.songs ?? []
        }
        isLoading = false
    }

    private func removeSong(at index: Int) async {
        songs.remove(at: index)
        await libraryStore.removeSongsFromPlaylist(playlist, indices: [index])
    }

    private func removeSongs(at offsets: IndexSet) async {
        let indices = Array(offsets).sorted(by: >)
        songs.remove(atOffsets: offsets)
        await libraryStore.removeSongsFromPlaylist(playlist, indices: indices)
    }

    private func syncOrder() async {
        // Subsonic hat kein direktes "reorder" — alle alten Indizes entfernen,
        // dann alle in neuer Reihenfolge per ID wieder hinzufügen (ein Aufruf, API macht removes zuerst)
        let newIds = songs.map(\.id)
        let totalBefore = (playlist.songCount ?? songs.count)
        let allOldIndices = Array(0..<totalBefore)
        try? await SubsonicAPIService.shared.updatePlaylist(
            id: playlist.id,
            songIdsToAdd: newIds,
            songIndicesToRemove: allOldIndices
        )
    }
}
