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
                        Label(tr("playlists.add.to.playlist.new_playlist"), systemImage: "plus.circle")
                            .foregroundStyle(accentColor)
                    }
                }

                if !visiblePlaylists.isEmpty {
                    Section(tr("playlists.add.to.playlist.add_playlist")) {
                        ForEach(visiblePlaylists) { playlist in
                            Button {
                                guard addingToPlaylistId == nil else { return }
                                addingToPlaylistId = playlist.id
                                Task {
                                    await libraryStore.addSongsToPlaylist(playlist, songIds: songIds)
                                    addingToPlaylistId = nil
                                    toast = ShelveToast(message: tr("playlists.add.to.playlist.added_value", String(describing: playlist.name)))
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
                                            Text("\(count) \(tr("car.play.car.play.library.songs"))")
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
            .navigationTitle(tr("playlists.add.to.playlist.add_playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("downloads.cancel"), role: .cancel) { dismiss() }
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
                Section(tr("library.name")) {
                    TextField(tr("playlists.add.to.playlist.my_playlist"), text: $newPlaylistName)
                        .focused($nameFieldFocused)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(tr("playlists.add.to.playlist.new_playlist.6dd3817e"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("downloads.cancel"), role: .cancel) {
                        showCreateSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("playlists.add.to.playlist.create_add")) {
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
