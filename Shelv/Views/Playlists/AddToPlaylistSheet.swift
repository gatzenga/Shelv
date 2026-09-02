import SwiftUI

private struct DuplicateSongsPrompt: Identifiable {
    let id: String
    let playlist: Playlist
    let songIds: [String]
    let duplicateIds: Set<String>

    init(playlist: Playlist, songIds: [String], duplicateIds: Set<String>) {
        self.id = playlist.id
        self.playlist = playlist
        self.songIds = songIds
        self.duplicateIds = duplicateIds
    }
}

struct AddToPlaylistSheet: View {
    let songIds: [String]
    @ObservedObject var libraryStore = LibraryStore.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @Environment(\.dismiss) private var dismiss

    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""
    @State private var addingToPlaylistId: String?
    @State private var toast: ShelveToast?
    @FocusState private var nameFieldFocused: Bool
    @State private var showDuplicatePrompt = false
    @State private var duplicatePrompt: DuplicateSongsPrompt?

    private var visiblePlaylists: [Playlist] { libraryStore.playlists }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newPlaylistName = ""
                        showCreateSheet = true
                    } label: {
                        Label(String(localized: "new_playlist"), systemImage: "plus.circle")
                            .foregroundStyle(accentColor)
                    }
                }

                if !visiblePlaylists.isEmpty {
                    Section(String(localized: "add_to_playlist_2")) {
                        ForEach(visiblePlaylists) { playlist in
                            Button {
                                guard addingToPlaylistId == nil else { return }
                                addingToPlaylistId = playlist.id
                                Task {
                                    let duplicateIds = await libraryStore.songIdsAlreadyInPlaylist(playlist, songIds: songIds)
                                    if duplicateIds.isEmpty {
                                        await performAdd(playlist: playlist, songIds: songIds)
                                    } else {
                                        addingToPlaylistId = nil
                                        duplicatePrompt = DuplicateSongsPrompt(playlist: playlist, songIds: songIds, duplicateIds: duplicateIds)
                                        showDuplicatePrompt = true
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    AlbumArtView(coverArtId: playlist.coverArt, size: 100, cornerRadius: 6)
                                        .frame(width: 40, height: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        if let count = playlist.songCount {
                                            Text("\(count) \(String(localized: "songs"))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if addingToPlaylistId == playlist.id {
                                        ProgressView()
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .foregroundStyle(.primary)
                            .disabled(addingToPlaylistId != nil && addingToPlaylistId != playlist.id)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "add_to_playlist_2"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "cancel"), role: .cancel) { dismiss() }
                }
            }
            .task {
                if libraryStore.playlists.isEmpty {
                    await libraryStore.loadPlaylists()
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                createAndAddSheet
            }
            .alert(
                String(localized: "song_already_in_playlist_title"),
                isPresented: $showDuplicatePrompt,
                presenting: duplicatePrompt
            ) { prompt in
                Button(String(localized: "discard"), role: .cancel) {
                    let remaining = prompt.songIds.filter { !prompt.duplicateIds.contains($0) }
                    guard !remaining.isEmpty else { return }
                    addingToPlaylistId = prompt.playlist.id
                    Task { await performAdd(playlist: prompt.playlist, songIds: remaining) }
                }
                Button(String(localized: "add_anyway")) {
                    addingToPlaylistId = prompt.playlist.id
                    Task { await performAdd(playlist: prompt.playlist, songIds: prompt.songIds) }
                }
            } message: { prompt in
                Text(String(
                    format: String(localized: prompt.duplicateIds.count == 1
                        ? "song_already_in_playlist_message"
                        : "songs_already_in_playlist_message_format"),
                    prompt.duplicateIds.count
                ))
            }
            .shelveToast($toast)
        }
        .tint(accentColor)
    }

    private func performAdd(playlist: Playlist, songIds: [String]) async {
        let success = await libraryStore.addSongsToPlaylist(playlist, songIds: songIds)
        addingToPlaylistId = nil
        if success {
            haptic()
            toast = ShelveToast(message: String(format: String(localized: "added_to_playlist_format"), playlist.name))
            try? await Task.sleep(for: .milliseconds(1200))
            dismiss()
        }
    }

    private var createAndAddSheet: some View {
        NavigationStack {
            Form {
                Section(String(localized: "name")) {
                    TextField(String(localized: "my_playlist"), text: $newPlaylistName)
                        .focused($nameFieldFocused)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(String(localized: "new_playlist_2"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "cancel"), role: .cancel) {
                        showCreateSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "create_add")) {
                        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        showCreateSheet = false
                        Task {
                            await libraryStore.createPlaylist(name: name, songIds: songIds)
                            dismiss()
                        }
                    }
                    .bold()
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .tint(accentColor)
        }
        .presentationSizing(.page)
        .presentationCornerRadius(24)
        .presentationDragIndicator(.visible)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                nameFieldFocused = true
            }
        }
    }
}
