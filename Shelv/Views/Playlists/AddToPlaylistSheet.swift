import SwiftUI

struct AddToPlaylistSheet: View {
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
        libraryStore.playlists.filter { !recapStore.recapPlaylistIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newPlaylistName = ""
                        showCreateSheet = true
                    } label: {
                        Label(tr("New Playlist…", "Neue Playlist…"), systemImage: "plus.circle")
                            .foregroundStyle(accentColor)
                    }
                }

                if !visiblePlaylists.isEmpty {
                    Section(tr("Add to Playlist", "Zu Playlist hinzufügen")) {
                        ForEach(visiblePlaylists) { playlist in
                            Button {
                                guard addingToPlaylistId == nil else { return }
                                addingToPlaylistId = playlist.id
                                Task {
                                    await libraryStore.addSongsToPlaylist(playlist, songIds: songIds)
                                    addingToPlaylistId = nil
                                    toast = ShelveToast(message: tr("Added to \"\(playlist.name)\"", "Zu \"\(playlist.name)\" hinzugefügt"))
                                    try? await Task.sleep(for: .milliseconds(1200))
                                    dismiss()
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
                                            Text("\(count) \(tr("Songs", "Titel"))")
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
            .navigationTitle(tr("Add to Playlist", "Zu Playlist hinzufügen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("Cancel", "Abbrechen"), role: .cancel) { dismiss() }
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
                Section(tr("Name", "Name")) {
                    TextField(tr("My Playlist", "Meine Playlist"), text: $newPlaylistName)
                        .focused($nameFieldFocused)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(tr("New Playlist", "Neue Playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("Cancel", "Abbrechen"), role: .cancel) {
                        showCreateSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("Create & Add", "Erstellen & Hinzufügen")) {
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
        .presentationDetents([.medium])
        .presentationCornerRadius(24)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                nameFieldFocused = true
            }
        }
    }
}
