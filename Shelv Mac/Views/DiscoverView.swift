import SwiftUI

struct DiscoverView: View {
    @StateObject private var vm = DiscoverViewModel()
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @AppStorage("recapEnabled") private var recapEnabled = false
    @State private var mixLoading: String?
    private let player = AudioPlayerService.shared

    @ViewBuilder
    var body: some View {
        if offlineMode.isOffline {
            Group {
                if downloadStore.songs.isEmpty {
                    offlineEmptyState
                } else {
                    offlineMixState
                }
            }
            .navigationTitle(String(localized: "discover"))
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    ThemePickerButton()
                }
                ToolbarItem(placement: .automatic) {
                    OfflineRecapToolbarItem()
                }
            }
            .onChange(of: offlineMode.isOffline) { _, isOffline in
                if !isOffline { Task { await vm.load() } }
            }
        } else {
            onlineBody
        }
    }

    private var offlineMixState: some View {
        VStack(spacing: 20) {
            Text(String(localized: "offline_mixes"))
                .font(.title2).bold()
            VStack(spacing: 10) {
                MixButton(
                    title: String(localized: "play_all_downloads"),
                    icon: "play.fill",
                    color: .blue,
                    isLoading: mixLoading == "offline_play"
                ) {
                    mixLoading = "offline_play"
                    loadOfflineMix(type: "offline_play")
                    mixLoading = nil
                }
                MixButton(
                    title: String(localized: "shuffle_all_downloads"),
                    icon: "shuffle",
                    color: .orange,
                    isLoading: mixLoading == "offline_shuffle"
                ) {
                    mixLoading = "offline_shuffle"
                    loadOfflineMix(type: "offline_shuffle")
                    mixLoading = nil
                }
                MixButton(
                    title: String(localized: "mix_latest_downloads"),
                    icon: "arrow.down.circle.fill",
                    color: .green,
                    isLoading: mixLoading == "offline_newest"
                ) {
                    mixLoading = "offline_newest"
                    loadOfflineMix(type: "offline_newest")
                    mixLoading = nil
                }
            }
            .frame(maxWidth: 480)
            Button {
                offlineMode.exitOfflineMode()
            } label: {
                Label(String(localized: "go_online"), systemImage: "wifi")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadOfflineMix(type: String) {
        let allSongs = downloadStore.songs.map { $0.asSong() }
        guard !allSongs.isEmpty else { return }

        switch type {
        case "offline_play":
            let sorted = allSongs.sorted {
                let a = desktopStripArticle($0.artist ?? "")
                    .localizedStandardCompare(desktopStripArticle($1.artist ?? ""))
                if a != .orderedSame { return a == .orderedAscending }
                let b = ($0.album ?? "").localizedStandardCompare($1.album ?? "")
                if b != .orderedSame { return b == .orderedAscending }
                let d0 = $0.discNumber ?? 0, d1 = $1.discNumber ?? 0
                if d0 != d1 { return d0 < d1 }
                return ($0.track ?? 0) < ($1.track ?? 0)
            }
            player.play(songs: Array(sorted.prefix(500)))

        case "offline_shuffle":
            let sampled = Array(allSongs.shuffled().prefix(500))
            player.playShuffled(songs: sampled)

        case "offline_newest":
            let top100 = downloadStore.songs
                .sorted { $0.addedAt > $1.addedAt }
                .prefix(100)
                .map { $0.asSong() }
            player.playShuffled(songs: Array(top100))

        default:
            break
        }
    }

    private var offlineEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text(String(localized: "you_are_offline"))
                .font(.title2.bold())
            Text(String(localized: "switch_to_your_downloads_in_the_sidebar_or_use_sea"))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            Button {
                offlineMode.exitOfflineMode()
            } label: {
                Label(String(localized: "go_online"), systemImage: "wifi")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var onlineBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {

                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "smart_mixes"))
                        .font(.title2).bold()
                    VStack(spacing: 10) {
                        MixButton(
                            title: String(localized: "mix_newest_tracks"),
                            icon: "sparkles",
                            color: .blue,
                            isLoading: mixLoading == "newest"
                        ) {
                            mixLoading = "newest"
                            await vm.playMixNewest()
                            mixLoading = nil
                        }
                        MixButton(
                            title: String(localized: "mix_most_played"),
                            icon: "chart.bar.fill",
                            color: .orange,
                            isLoading: mixLoading == "frequent"
                        ) {
                            mixLoading = "frequent"
                            await vm.playMixFrequent()
                            mixLoading = nil
                        }
                        MixButton(
                            title: String(localized: "mix_recently_played"),
                            icon: "clock.fill",
                            color: .green,
                            isLoading: mixLoading == "recent"
                        ) {
                            mixLoading = "recent"
                            await vm.playMixRecent()
                            mixLoading = nil
                        }
                        MixButton(
                            title: String(localized: "mix_shuffle_all"),
                            icon: "shuffle",
                            color: .purple,
                            isLoading: mixLoading == "random"
                        ) {
                            mixLoading = "random"
                            await vm.playMixRandom()
                            mixLoading = nil
                        }
                    }
                }

                if vm.isLoading {
                    ProgressView(String(localized: "loading"))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    if !vm.recentlyAdded.isEmpty {
                        AlbumShelfSection(title: String(localized: "recently_added"), albums: vm.recentlyAdded)
                    }
                    if !vm.recentlyPlayed.isEmpty {
                        AlbumShelfSection(title: String(localized: "recently_played"), albums: vm.recentlyPlayed)
                    }
                    if !vm.frequentlyPlayed.isEmpty {
                        AlbumShelfSection(title: String(localized: "frequently_played"), albums: vm.frequentlyPlayed)
                    }
                    if !vm.randomAlbums.isEmpty {
                        AlbumShelfSection(
                            title: String(localized: "random_albums"),
                            albums: vm.randomAlbums,
                            refreshAction: { await vm.refreshRandom() }
                        )
                    }
                }

                if let err = vm.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(24)
        }
        .navigationTitle(String(localized: "discover"))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ThemePickerButton()
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        async let discover:  Void = vm.load()
                        async let playlists: Void = libraryStore.loadPlaylists()
                        async let sync:      Void = CloudKitSyncService.shared.syncNow()
                        _ = await (discover, playlists, sync)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
                .help(String(localized: "reload"))
            }
            ToolbarItem(placement: .automatic) {
                Divider()
            }
            if recapEnabled {
                ToolbarItem(placement: .automatic) {
                    RecapToolbarButton()
                }
            }
            ToolbarItem(placement: .automatic) {
                InsightsToolbarButton()
            }
        }
        .task { await vm.load() }
        .onChange(of: appState.serverStore.activeServerID) { _, _ in
            vm.reset()
            Task { await vm.load() }
        }
    }
}

struct MixButton: View {
    let title: String
    let icon: String
    let color: Color
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body.bold())
                    .frame(width: 24)
                Text(title)
                    .font(.body.bold())
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(color)
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25), lineWidth: 1))
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

struct AlbumShelfSection: View {
    let title: String
    let albums: [Album]
    var refreshAction: (() async -> Void)? = nil

    private let cardWidth: CGFloat   = 150
    private let cardSpacing: CGFloat  = 16
    private let shelfHeight: CGFloat  = 196
    private let cardsPerStep: Int     = 3

    @State private var firstVisible: Int = 0
    @State private var isRefreshing = false

    private var atStart: Bool { firstVisible == 0 }
    private var atEnd: Bool   { firstVisible + cardsPerStep >= albums.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.title2).bold()
                Spacer()
                HStack(spacing: 6) {
                    if let refreshAction {
                        ShelfNavButton(icon: isRefreshing ? "arrow.clockwise" : "dice", disabled: isRefreshing) {
                            isRefreshing = true
                            firstVisible = 0
                            await refreshAction()
                            isRefreshing = false
                        }
                    }
                    ShelfNavButton(icon: "chevron.left", disabled: atStart) {
                        firstVisible = max(0, firstVisible - cardsPerStep)
                    }
                    ShelfNavButton(icon: "chevron.right", disabled: atEnd) {
                        firstVisible = min(albums.count - cardsPerStep, firstVisible + cardsPerStep)
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: cardSpacing) {
                        ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album)
                            .id(index)
                        }
                    }
                    .padding(.leading, 2)
                    .padding(.top, 8)
                }
                .frame(height: shelfHeight + 8)
                .clipped()
                .onChange(of: firstVisible) { _, newValue in
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(newValue, anchor: .leading)
                    }
                }
            }
        }
    }
}

struct ShelfNavButton: View {
    let icon: String
    let disabled: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.callout.bold())
                .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 28)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct AlbumCard: View {
    let album: Album
    @State private var isHovered = false

    private var coverURL: URL? {
        guard let id = album.coverArt else { return nil }
        return SubsonicAPIService.shared.coverArtURL(id: id, size: 200)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverArtView(url: coverURL, size: 150, cornerRadius: 8)
                .overlay(alignment: .bottomTrailing) {
                    AlbumDownloadBadge(albumId: album.id)
                        .padding(4)
                }
                .shadow(color: .black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 8 : 4)
            Text(album.name)
                .font(.caption.bold())
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            if let artist = album.artist {
                Text(artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
            }
        }
        .scaleEffect(isHovered ? 1.03 : 1.0, anchor: .bottom)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct InsightsToolbarButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Button {
            openWindow(id: "insights")
        } label: {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(themeColor)
        }
        .help(String(localized: "insights"))
    }
}

struct RecapToolbarButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Button {
            openWindow(id: "recap")
        } label: {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(themeColor)
        }
        .help(String(localized: "recap"))
    }
}

struct ThemePickerButton: View {
    @AppStorage("themeColor") private var themeColorName: String = "violet"
    @State private var showPicker = false

    var body: some View {
        Button { showPicker.toggle() } label: {
            Image(systemName: "paintpalette.fill")
                .foregroundStyle(AppTheme.color(for: themeColorName))
        }
        .help(String(localized: "choose_color"))
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            ThemePickerPopover(themeColorName: $themeColorName)
        }
    }
}

struct ThemePickerPopover: View {
    @Binding var themeColorName: String

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 10), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "color"))
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AppTheme.options, id: \.name) { option in
                    Button {
                        themeColorName = option.name
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 34, height: 34)
                            .overlay {
                                if themeColorName == option.name {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(
                                            option.useDarkCheckmark ? Color.black : Color.white
                                        )
                                }
                            }
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help(appLang == "de" ? option.nameDE : option.nameEN)
                }
            }
        }
        .padding(16)
        .frame(width: 240)
    }
}

private struct OfflineRecapToolbarItem: View {
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var recapStore = RecapStore.shared
    @AppStorage("recapEnabled") private var recapEnabled = false

    var body: some View {
        if recapEnabled && !downloadStore.downloadedPlaylistIds.isDisjoint(with: recapStore.recapPlaylistIds) {
            RecapToolbarButton()
        }
    }
}

private func desktopStripArticle(_ title: String) -> String {
    let lower = title.lowercased()
    let prefixes: [String] = [
        "the ", "an ", "a ",
        "der ", "die ", "das ", "dem ", "den ", "des ",
        "eine ", "einer ", "einem ", "einen ", "ein ",
        "les ", "le ", "la ", "l\u{2019}", "l'",
        "une ", "des ", "un ",
        "los ", "las ", "el ", "una ", "un ",
        "gli ", "uno ", "una ", "il ", "lo ",
        "umas ", "uma ", "uns ", "um ", "os ", "as ",
        "het ", "een ", "de ",
    ]
    for p in prefixes where lower.hasPrefix(p) { return String(title.dropFirst(p.count)) }
    return title
}

#Preview {
    DiscoverView()
        .frame(width: 900, height: 700)
        .environmentObject(AppState.shared)
}
