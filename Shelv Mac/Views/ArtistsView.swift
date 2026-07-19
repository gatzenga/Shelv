import SwiftUI

struct ArtistsView: View {
    @ObservedObject private var vm = LibraryViewModel.shared
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("artistViewIsGrid") private var isGrid: Bool = true
    @AppStorage("downloadsOnlyFilter") private var showDownloadsOnly: Bool = false
    @State private var searchText: String = ""
    @State private var displayArtists: [Artist] = []
    @State private var downloadedArtistNames: Set<String> = []
    @State private var displayRebuildTask: Task<Void, Never>?

    private var effectiveShowDownloadsOnly: Bool {
        offlineMode.isOffline || showDownloadsOnly
    }

    private func rebuildDisplayArtists() {
        displayRebuildTask?.cancel()
        let isOffline = offlineMode.isOffline
        let downloadsOnly = effectiveShowDownloadsOnly
        let sortedArtists = vm.sortedArtists.isEmpty && !vm.artists.isEmpty ? vm.artists : vm.sortedArtists
        let serverArtistsEmpty = vm.artists.isEmpty
        let downloadedArtists = downloadStore.artists.map { $0.asArtist() }
        let downloadedCountByName = Dictionary(
            downloadStore.artists.map { ($0.name, $0.albumCount) },
            uniquingKeysWith: { first, _ in first }
        )
        let query = searchText

        displayRebuildTask = Task.detached(priority: .userInitiated) {
            let baseArtists: [Artist]
            if isOffline && serverArtistsEmpty {
                baseArtists = downloadedArtists
            } else if downloadsOnly {
                baseArtists = sortedArtists
                    .filter { downloadedCountByName[$0.name] != nil }
                    .map {
                        Artist(
                            id: $0.id,
                            name: $0.name,
                            sortName: $0.sortName,
                            albumCount: downloadedCountByName[$0.name],
                            coverArt: $0.coverArt,
                            starred: $0.starred
                        )
                    }
            } else {
                baseArtists = sortedArtists
            }

            let result = query.isEmpty
                ? baseArtists
                : baseArtists.filter { $0.name.localizedCaseInsensitiveContains(query) }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                displayArtists = result
                downloadedArtistNames = Set(downloadedCountByName.keys)
            }
        }
    }

    var body: some View {
        let displayArtists = self.displayArtists
        let lastArtistID = displayArtists.last?.id

        VStack(spacing: 0) {
            HStack {
                TextField(String(localized: "filter"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Picker("\(String(localized: "sort")):", selection: $vm.artistSortOption) {
                    ForEach(ArtistSortOption.allCases.filter { !offlineMode.isOffline || !$0.requiresServer }, id: \.self) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .frame(width: 180)
                if vm.artistSortOption != .name {
                    Button {
                        vm.artistSortDirection = vm.artistSortDirection == .ascending ? .descending : .ascending
                    } label: {
                        Image(systemName: vm.artistSortDirection == .ascending ? "arrow.up" : "arrow.down")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help(vm.artistSortDirection == .ascending ? String(localized: "ascending") : String(localized: "descending"))
                }
                Button { isGrid.toggle() } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help(isGrid ? String(localized: "list_view") : String(localized: "grid_view"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if vm.isLoadingArtists {
                ProgressView(String(localized: "loading_artists"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)], spacing: 20) {
                        ForEach(displayArtists) { artist in
                            NavigationLink(value: artist) {
                                ArtistGridItem(
                                    artist: artist,
                                    isDownloaded: downloadedArtistNames.contains(artist.name)
                                )
                                .equatable()
                            }
                            .buttonStyle(.plain)
                            .artistContextMenu(artist)
                        }
                    }
                    .padding(20)
                }
                .overlay {
                    if displayArtists.isEmpty && !vm.artists.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayArtists) { artist in
                            NavigationLink(value: artist) {
                                ArtistListRow(
                                    artist: artist,
                                    isDownloaded: downloadedArtistNames.contains(artist.name)
                                )
                                .equatable()
                            }
                            .buttonStyle(.plain)
                            .artistContextMenu(artist)
                            if artist.id != lastArtistID {
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .overlay {
                    if displayArtists.isEmpty && !vm.artists.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }

            if let err = vm.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding()
            }
        }
        .navigationTitle(String(format: String(localized: "artists_count_format"), displayArtists.count))
        .onAppear { rebuildDisplayArtists() }
        .onReceive(vm.$sortedArtists) { _ in rebuildDisplayArtists() }
        .onReceive(downloadStore.catalogPublisher) { _ in rebuildDisplayArtists() }
        .onChange(of: searchText) { _, _ in rebuildDisplayArtists() }
        .onChange(of: showDownloadsOnly) { _, _ in rebuildDisplayArtists() }
        .onChange(of: offlineMode.isOffline) { _, isOffline in
            if isOffline && vm.artistSortOption.requiresServer {
                vm.artistSortOption = .name
            }
            rebuildDisplayArtists()
        }
        .onDisappear {
            displayRebuildTask?.cancel()
            displayRebuildTask = nil
        }
        .task { await vm.loadArtists() }
    }
}

struct ArtistGridItem: View, Equatable {
    let artist: Artist
    let isDownloaded: Bool
    @Environment(\.themeColor) private var themeColor
    @State private var isHovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artist == rhs.artist && lhs.isDownloaded == rhs.isDownloaded
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                CoverArtView(
                    coverArtID: artist.coverArt,
                    requestSize: 160,
                    size: 140,
                    isCircle: true
                )
                    .shadow(color: .black.opacity(isHovered ? 0.3 : 0.12), radius: isHovered ? 10 : 4)
                    .scaleEffect(isHovered ? 1.03 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(themeColor, in: Circle())
                        .padding(6)
                }
            }
            Text(artist.name)
                .font(.caption.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let count = artist.albumCount {
                Text(String(format: String(localized: "count_albums_format"), count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 140)
        .onHover { isHovered = $0 }
    }
}

struct ArtistListRow: View, Equatable {
    let artist: Artist
    let isDownloaded: Bool
    @Environment(\.themeColor) private var themeColor
    @State private var isHovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artist == rhs.artist && lhs.isDownloaded == rhs.isDownloaded
    }

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(
                coverArtID: artist.coverArt,
                requestSize: 120,
                size: 52,
                isCircle: true
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .lineLimit(1)
                if let count = artist.albumCount {
                    Text(String(format: String(localized: "count_albums_format"), count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(themeColor, in: Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color(NSColor.windowBackgroundColor)
            if isHovered {
                Color.primary.opacity(0.05)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

#Preview {
    ArtistsView()
        .frame(width: 900, height: 700)
        .environmentObject(LibraryViewModel())
}
