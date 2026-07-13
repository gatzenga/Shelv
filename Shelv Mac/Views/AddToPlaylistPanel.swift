import SwiftUI

struct AddToPlaylistPanel: View {
    @AppStorage("recapEnabled") private var recapEnabled = false
    let songIds: [String]
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @StateObject private var recapStore = RecapStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor

    @State private var newPlaylistName = ""

    private var nonRecapPlaylists: [Playlist] {
        recapEnabled
            ? libraryStore.playlists.filter { !recapStore.recapPlaylistIds.contains($0.id) }
            : libraryStore.playlists
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(String(localized: "add_to_playlist_2"))
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            List {
                // Existing playlists
                if !nonRecapPlaylists.isEmpty {
                    Section(String(localized: "existing_playlists")) {
                        ForEach(nonRecapPlaylists) { playlist in
                            Button {
                                Task {
                                    let success = await libraryStore.addSongsToPlaylist(playlist, songIds: songIds)
                                    if success { dismiss() }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    CoverArtView(
                                        url: playlist.coverArt.flatMap {
                                            SubsonicAPIService.shared.coverArtURL(id: $0, size: 60)
                                        },
                                        size: 36,
                                        cornerRadius: 4
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                        if let count = playlist.songCount {
                                            Text(String(format: String(localized: "count_tracks_format"), count))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Create new
                Section(String(localized: "create_new")) {
                    HStack {
                        TextField(String(localized: "playlist_name"), text: $newPlaylistName)
                            .textFieldStyle(.plain)
                        Button(String(localized: "create")) {
                            let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            Task {
                                await libraryStore.createPlaylist(name: name)
                                // Find and add to new playlist
                                if let created = libraryStore.playlists.first(where: { $0.name == name }) {
                                    await libraryStore.addSongsToPlaylist(created, songIds: songIds)
                                }
                                dismiss()
                            }
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .buttonStyle(.borderedProminent)
                        .tint(themeColor)
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 380, height: 440)
        .task {
            if libraryStore.playlists.isEmpty {
                await libraryStore.loadPlaylists()
            }
        }
    }
}
