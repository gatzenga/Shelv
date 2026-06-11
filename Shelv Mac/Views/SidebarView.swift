import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @StateObject private var recapStore = RecapStore.shared
    @ObservedObject private var downloadStore = DownloadStore.shared
    @Binding var selection: SidebarItem?
    @Binding var selectedPlaylist: Playlist?
    @Environment(\.themeColor) private var themeColor
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false

    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""

    private var nonRecapPlaylists: [Playlist] {
        libraryStore.playlists.filter { !recapStore.recapPlaylistIds.contains($0.id) }
    }

    private var visiblePlaylists: [Playlist] {
        let base = nonRecapPlaylists
        guard offlineMode.isOffline || showDownloadsOnly else { return base }
        return base.filter { downloadStore.downloadedPlaylistIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarRow(item: .discover, isSelected: selection == .discover && selectedPlaylist == nil, themeColor: themeColor) {
                selection = .discover
                selectedPlaylist = nil
                appState.navigationPath = NavigationPath()
            }
            SidebarRow(item: .albums, isSelected: selection == .albums && selectedPlaylist == nil, themeColor: themeColor) {
                selection = .albums
                selectedPlaylist = nil
                appState.navigationPath = NavigationPath()
            }
            SidebarRow(item: .artists, isSelected: selection == .artists && selectedPlaylist == nil, themeColor: themeColor) {
                selection = .artists
                selectedPlaylist = nil
                appState.navigationPath = NavigationPath()
            }
            if enableFavorites {
                SidebarRow(item: .favorites, isSelected: selection == .favorites && selectedPlaylist == nil, themeColor: themeColor) {
                    selection = .favorites
                    selectedPlaylist = nil
                    appState.navigationPath = NavigationPath()
                }
            }
            SidebarRow(item: .search, isSelected: selection == .search && selectedPlaylist == nil, themeColor: themeColor) {
                selection = .search
                selectedPlaylist = nil
                appState.navigationPath = NavigationPath()
            }

            if enablePlaylists {
                Divider()
                    .padding(.vertical, 8)

                HStack {
                    Text(String(localized: "playlists"))
                        .font(.callout.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        newPlaylistName = ""
                        showCreatePlaylist = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.callout.bold())
                            .foregroundStyle(themeColor)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "new_playlist"))
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

                if libraryStore.isLoadingPlaylists && visiblePlaylists.isEmpty {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.horizontal, 10)
                } else if visiblePlaylists.isEmpty {
                    Text(String(localized: "no_playlists"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                } else {
                    ForEach(visiblePlaylists) { playlist in
                        PlaylistSidebarRow(
                            playlist: playlist,
                            isSelected: selectedPlaylist?.id == playlist.id,
                            themeColor: themeColor
                        ) {
                            selectedPlaylist = playlist
                            selection = nil
                            appState.navigationPath = NavigationPath()
                        }
                    }
                }
            }

            Spacer()

            if enableDownloads {
                Divider()
                SidebarBatchProgress()
                downloadsFooter
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 290)
        .task {
            if enableFavorites && libraryStore.starredAlbums.isEmpty {
                await libraryStore.loadStarred()
            }
            if enablePlaylists && libraryStore.playlists.isEmpty {
                await libraryStore.loadPlaylists()
            }
        }
        .onChange(of: enableFavorites) { _, new in
            if new { Task { await libraryStore.loadStarred() } }
        }
        .onChange(of: enablePlaylists) { _, new in
            if new { Task { await libraryStore.loadPlaylists() } }
        }
        .onChange(of: selection) { _, _ in
            if enablePlaylists { Task { await libraryStore.loadPlaylists() } }
        }
        .onChange(of: selectedPlaylist) { _, _ in
            if enablePlaylists { Task { await libraryStore.loadPlaylists() } }
        }
        .alert(String(localized: "new_playlist"), isPresented: $showCreatePlaylist) {
            TextField(String(localized: "name"), text: $newPlaylistName)
            Button(String(localized: "create")) {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await libraryStore.createPlaylist(name: name) }
            }
            Button(String(localized: "cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "enter_a_name_for_the_new_playlist"))
        }
    }

    @ViewBuilder
    private var downloadsFooter: some View {
        if offlineMode.isOffline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(themeColor)
                Text(String(localized: "offline_mode"))
                    .font(.caption.bold())
                    .foregroundStyle(themeColor)
                Spacer()
                Button {
                    offlineMode.exitOfflineMode()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "exit_offline_mode"))
            }
        } else {
            Toggle(isOn: $showDownloadsOnly) {
                Label(String(localized: "downloads_only"), systemImage: "arrow.down.circle")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
        }
    }
}

private struct SidebarBatchProgress: View {
    @ObservedObject private var downloadStore = DownloadStore.shared
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        if let progress = downloadStore.batchProgress {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(themeColor)
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await DownloadService.shared.cancelBatch() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "cancel_download"))
                }
                ProgressView(value: progress.fraction)
                    .tint(themeColor)
                    .scaleEffect(y: 0.7, anchor: .center)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let themeColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(item.displayName, systemImage: item.icon)
                .font(.body)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? themeColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? themeColor.opacity(0.15)
                                : isHovered
                                    ? Color.primary.opacity(0.06)
                                    : Color.clear
                        )
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct PlaylistSidebarRow: View {
    let playlist: Playlist
    let isSelected: Bool
    let themeColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(playlist.name, systemImage: "music.note.list")
                .font(.body)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? themeColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? themeColor.opacity(0.15)
                                : isHovered
                                    ? Color.primary.opacity(0.06)
                                    : Color.clear
                        )
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

#Preview {
    SidebarView(
        selection: .constant(.discover),
        selectedPlaylist: .constant(nil)
    )
    .environmentObject(AppState.shared)
    .environmentObject(LibraryViewModel())
    .frame(width: 200, height: 400)
}
