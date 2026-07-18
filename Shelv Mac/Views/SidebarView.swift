import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @StateObject private var recapStore = RecapStore.shared
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var pinStore = PinnedPlaylistStore.shared
    @Binding var selection: SidebarItem?
    @Binding var selectedPlaylist: Playlist?
    @Environment(\.themeColor) private var themeColor
    @AppStorage(PersonalizationPreferenceKey.showFavoritesInLibrary) private var showFavoritesInLibrary = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsInSidebar = true
    @AppStorage(PersonalizationPreferenceKey.showRadio) private var showRadio = true
    @AppStorage("enableDownloads") private var enableDownloads = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false
    @AppStorage("playlistSortOption") private var sortOptionRaw: String = PlaylistSortOption.alphabetical.rawValue
    private var sortOption: PlaylistSortOption { PlaylistSortOption(rawValue: sortOptionRaw) ?? .alphabetical }
    @AppStorage("playlistSortDirection") private var sortDirectionRaw: String = SortDirection.ascending.rawValue
    private var sortDirection: SortDirection { SortDirection(rawValue: sortDirectionRaw) ?? .ascending }

    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""

    private var nonRecapPlaylists: [Playlist] {
        guard recapEnabled else { return libraryStore.playlists }
        return libraryStore.playlists.filter { !recapStore.recapPlaylistIds.contains($0.id) }
    }

    private var visiblePlaylists: [Playlist] {
        var base = nonRecapPlaylists
        if offlineMode.isOffline || showDownloadsOnly {
            base = base.filter { downloadStore.downloadedPlaylistIds.contains($0.id) }
        }
        return sortedPlaylists(base)
    }

    private func sortedPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let sorted = applySortOption(playlists)
        // Angepinnte oben, zuletzt angepinnt zuoberst (pinRank 0). Rest behält Sortierung.
        let pinned = sorted.filter { pinStore.isPinned($0.id) }
            .sorted { (pinStore.pinRank($0.id) ?? 0) < (pinStore.pinRank($1.id) ?? 0) }
        let rest = sorted.filter { !pinStore.isPinned($0.id) }
        return pinned + rest
    }

    private func applySortOption(_ playlists: [Playlist]) -> [Playlist] {
        switch sortOption {
        case .alphabetical:
            // Fix A–Z, kein Richtungs-Toggle (analog Alben).
            return playlists.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .lastModified:
            let asc = playlists.sorted { ($0.changed ?? .distantPast) < ($1.changed ?? .distantPast) }
            return sortDirection == .descending ? asc.reversed() : asc
        case .dateCreated:
            let asc = playlists.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
            return sortDirection == .descending ? asc.reversed() : asc
        }
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
            if showFavoritesInLibrary {
                SidebarRow(item: .favorites, isSelected: selection == .favorites && selectedPlaylist == nil, themeColor: themeColor) {
                    selection = .favorites
                    selectedPlaylist = nil
                    appState.navigationPath = NavigationPath()
                }
            }
            if showRadio && !offlineMode.isOffline {
                SidebarRow(item: .radio, isSelected: selection == .radio && selectedPlaylist == nil, themeColor: themeColor) {
                    selection = .radio
                    selectedPlaylist = nil
                    appState.navigationPath = NavigationPath()
                }
            }
            SidebarRow(item: .search, isSelected: selection == .search && selectedPlaylist == nil, themeColor: themeColor) {
                selection = .search
                selectedPlaylist = nil
                appState.navigationPath = NavigationPath()
            }

            if showPlaylistsInSidebar {
                Divider()
                    .padding(.vertical, 8)

                HStack {
                    Text(String(localized: "playlists"))
                        .font(.callout.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    playlistSortMenu
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

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
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
                                    themeColor: themeColor,
                                    isPinned: pinStore.isPinned(playlist.id)
                                ) {
                                    selectedPlaylist = playlist
                                    selection = nil
                                    appState.navigationPath = NavigationPath()
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }

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
        .navigationSplitViewColumnWidth(min: 190, ideal: 235, max: 310)
        .task {
            if showFavoritesInLibrary && libraryStore.starredAlbums.isEmpty {
                await libraryStore.loadStarred()
            }
            if showPlaylistsInSidebar && libraryStore.playlists.isEmpty {
                await libraryStore.loadPlaylists()
            }
        }
        .onChange(of: showFavoritesInLibrary) { _, new in
            if new { Task { await libraryStore.loadStarred() } }
        }
        .onChange(of: showPlaylistsInSidebar) { _, new in
            if new { Task { await libraryStore.loadPlaylists() } }
        }
        .onChange(of: showRadio) { _, new in
            if !new && selection == .radio {
                selection = .search
                selectedPlaylist = nil
                appState.navigationPath = NavigationPath()
            }
        }
        .onChange(of: offlineMode.isOffline) { _, isOffline in
            if isOffline && selection == .radio {
                selection = .search
                selectedPlaylist = nil
                appState.navigationPath = NavigationPath()
            }
        }
        .onChange(of: selection) { _, _ in
            if showPlaylistsInSidebar { Task { await libraryStore.loadPlaylists() } }
        }
        .onChange(of: selectedPlaylist) { _, _ in
            if showPlaylistsInSidebar { Task { await libraryStore.loadPlaylists() } }
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

    private var playlistSortMenu: some View {
        Menu {
            Picker(selection: $sortOptionRaw) {
                ForEach(PlaylistSortOption.allCases, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Label(String(localized: "sort"), systemImage: "arrow.up.arrow.down")
            }

            if sortOption != .alphabetical {
                Picker(selection: $sortDirectionRaw) {
                    ForEach(SortDirection.allCases, id: \.rawValue) { dir in
                        Text(dir.label).tag(dir.rawValue)
                    }
                } label: {
                    Label(String(localized: "direction"), systemImage: "arrow.up.and.down")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.callout.bold())
                .foregroundStyle(themeColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "sort"))
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
    @ObservedObject private var downloadActivity = DownloadActivityStore.shared
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        if let progress = downloadActivity.batchProgress {
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
    var isPinned: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label(playlist.name, systemImage: "music.note.list")
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? themeColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(themeColor)
                }
            }
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
