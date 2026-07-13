import SwiftUI

struct AddToPlaylistSheet: View {
    @AppStorage("recapEnabled") private var recapEnabled = false
    let songIds: [String]
    @ObservedObject var libraryStore = LibraryStore.shared
    @EnvironmentObject var recapStore: RecapStore
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @Environment(\.dismiss) private var dismiss

    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""
    @State private var addingToPlaylistId: String?
    @State private var toast: ShelveToast?
    @FocusState private var nameFieldFocused: Bool

    private var visiblePlaylists: [Playlist] {
        recapEnabled
            ? libraryStore.playlists.filter { !recapStore.recapPlaylistIds.contains($0.id) }
            : libraryStore.playlists
    }

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
                                    let success = await libraryStore.addSongsToPlaylist(playlist, songIds: songIds)
                                    addingToPlaylistId = nil
                                    if success {
                                        haptic()
                                        toast = ShelveToast(message: String(format: String(localized: "added_to_playlist_format"), playlist.name))
                                        try? await Task.sleep(for: .milliseconds(1200))
                                        dismiss()
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
            .shelveToast($toast)
        }
        .tint(accentColor)
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
