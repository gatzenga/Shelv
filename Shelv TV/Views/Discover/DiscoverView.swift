import SwiftUI

struct DiscoverView: View {
    let recapNavigationRequest: Int

    init(recapNavigationRequest: Int = 0) {
        self.recapNavigationRequest = recapNavigationRequest
    }

    @ObservedObject var library = LibraryStore.shared
    @AppStorage("mixUseDatabase") private var mixUseDatabase = false
    @AppStorage("themeColor") private var themeColor = "violet"
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage(PersonalizationPreferenceKey.showDiscoverInsights) private var showDiscoverInsights = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixNewest) private var showSmartMixNewest = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixFrequent) private var showSmartMixFrequent = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixRecent) private var showSmartMixRecent = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixRandom) private var showSmartMixRandom = true
    @AppStorage(PersonalizationPreferenceKey.discoverySectionOrder) private var discoverySectionOrderRaw = PersonalizationSettings.defaultDiscoverySectionOrderRaw
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

    private var accent: Color { AppTheme.color(for: themeColor) }

    private var visibleSmartMixes: [PersonalizationSmartMix] {
        PersonalizationSmartMix.allCases.filter(isSmartMixVisible)
    }

    private var orderedDiscoverySections: [PersonalizationDiscoverySection] {
        PersonalizationSettings.discoverySectionOrder(from: discoverySectionOrderRaw)
    }

    private var visibleDiscoverySections: [PersonalizationDiscoverySection] {
        orderedDiscoverySections.filter(isDiscoverySectionVisible)
    }

    private var discoverContentIsEmpty: Bool {
        newest.isEmpty
            && recent.isEmpty
            && frequent.isEmpty
            && random.isEmpty
    }

    @State private var newest: [Album] = []
    @State private var recent: [Album] = []
    @State private var frequent: [Album] = []
    @State private var random: [Album] = []
    @State private var showRequestedRecap = false
    @State private var handledRecapNavigationRequest = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    HStack {
                        Button {
                            Task {
                                if await OfflineModeService.shared.beginUserInitiatedServerRefresh() { return }
                                defer { OfflineModeService.shared.finishUserInitiatedServerRefresh() }
                                Task { await CloudKitSyncService.shared.syncNow() }
                                async let discover:  Void = load()
                                async let playlists: Void = LibraryStore.shared.loadPlaylists()
                                async let radio:     Void = RadioStationStore.shared.refresh()
                                _ = await (discover, playlists, radio)
                            }
                        } label: {
                            Label(String(localized: "refresh"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        HStack(spacing: 12) {
                            if recapEnabled {
                                NavigationLink { RecapView() } label: {
                                    Label(String(localized: "recap"), systemImage: "sparkles.rectangle.stack")
                                }
                                .buttonStyle(.bordered)
                            }
                            if showDiscoverInsights {
                                NavigationLink { InsightsView() } label: {
                                    Label(String(localized: "insights"), systemImage: "chart.bar.xaxis")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.horizontal, 50)
                    .focusSection()

                    ForEach(Array(visibleDiscoverySections.enumerated()), id: \.element) { index, section in
                        discoverySection(section, isFirstVisible: index == 0)
                    }
                }
                .padding(.vertical, 50)
            }
            .task(id: library.reloadID) { await load() }
            .navigationDestination(isPresented: $showRequestedRecap) {
                RecapView()
            }
            .onChange(of: recapNavigationRequest) { _, _ in
                handleRecapNavigationRequest()
            }
            .onAppear {
                handleRecapNavigationRequest()
            }
        }
    }

    private func handleRecapNavigationRequest() {
        guard recapNavigationRequest != handledRecapNavigationRequest else { return }
        handledRecapNavigationRequest = recapNavigationRequest
        showRequestedRecap = true
    }

    // MARK: - Daten

    private func load() async {
        async let n = try? api.getAlbumList(type: "newest", size: 20)
        async let r = try? api.getAlbumList(type: "recent", size: 20)
        async let f = try? api.getAlbumList(type: "frequent", size: 20)
        async let rnd = try? api.getAlbumList(type: "random", size: 20)
        newest = await n ?? []
        recent = await r ?? []
        frequent = await f ?? []
        random = await rnd ?? []
    }

    private func play(_ mix: PersonalizationSmartMix) async {
        let songs: [Song]
        switch mix {
        case .newest:   songs = (try? await api.getNewestSongs()) ?? []
        case .random:   songs = (try? await api.getRandomSongs(size: 500)) ?? []
        case .frequent: songs = await frequentMix()
        case .recent:   songs = await recentMix()
        }
        if !songs.isEmpty { player.playShuffled(songs: songs) }
    }

    private func frequentMix() async -> [Song] {
        if mixUseDatabase, let sid = api.activeServer?.stableId,
           await PlayLogService.shared.distinctSongCount(serverId: sid) >= 50 {
            let counts = await PlayLogService.shared.topSongs(serverId: sid, from: .distantPast, to: Date(), limit: 50)
            if !counts.isEmpty, let songs = try? await api.getSongsOrdered(ids: counts.map(\.songId)) { return songs }
        }
        return (try? await api.frequentMixFallbackSongs()) ?? []
    }

    private func recentMix() async -> [Song] {
        if mixUseDatabase, let sid = api.activeServer?.stableId,
           await PlayLogService.shared.distinctSongCount(serverId: sid) >= 50 {
            let ids = await PlayLogService.shared.recentUniqueSongIds(serverId: sid, limit: 50)
            if !ids.isEmpty, let songs = try? await api.getSongsOrdered(ids: ids) { return songs }
        }
        return (try? await api.getRecentSongs(limit: 50)) ?? []
    }

    // MARK: - UI

    private func isSmartMixVisible(_ mix: PersonalizationSmartMix) -> Bool {
        switch mix {
        case .newest: return showSmartMixNewest
        case .frequent: return showSmartMixFrequent
        case .recent: return showSmartMixRecent
        case .random: return showSmartMixRandom
        }
    }

    private func isDiscoverySectionVisible(_ section: PersonalizationDiscoverySection) -> Bool {
        switch section {
        case .smartMixes:
            #if DEBUG
            if api.isDemoActive {
                return !visibleSmartMixes.isEmpty
            }
            #endif
            return !visibleSmartMixes.isEmpty && !discoverContentIsEmpty
        case .recentlyAdded:
            return !newest.isEmpty
        case .recentlyPlayed:
            return !recent.isEmpty
        case .frequentlyPlayed:
            return !frequent.isEmpty
        case .randomAlbums:
            return !random.isEmpty
        }
    }

    @ViewBuilder
    private func discoverySection(_ section: PersonalizationDiscoverySection, isFirstVisible: Bool) -> some View {
        switch section {
        case .smartMixes:
            VStack(alignment: .leading, spacing: 16) {
                if !isFirstVisible {
                    Text(String(localized: "smart_mixes"))
                        .font(.title2).bold()
                        .padding(.horizontal, 50)
                }
                VStack(spacing: 16) {
                    ForEach(visibleSmartMixes) { mix in
                        MixPill(
                            title: NSLocalizedString(mix.titleKey, comment: ""),
                            icon: mix.systemImage,
                            accent: accent
                        ) {
                            await play(mix)
                        }
                    }
                }
                .padding(.horizontal, 50)
            }
            .focusSection()
        case .recentlyAdded:
            albumRow(String(localized: "recently_added"), newest)
        case .recentlyPlayed:
            albumRow(String(localized: "recently_played"), recent)
        case .frequentlyPlayed:
            albumRow(String(localized: "frequently_played"), frequent)
        case .randomAlbums:
            albumRow(String(localized: "random_albums"), random)
        }
    }

    /// Album-Karussell: scrollt über die volle Bildschirmbreite (edge-to-edge),
    /// der Inhalt startet aber bündig mit Titel/Pillen (50er-Padding im Inneren).
    @ViewBuilder
    private func albumRow(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title2).bold()
                    .padding(.horizontal, 50)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 40) {
                        ForEach(albums) { AlbumCard(album: $0, size: 240) }
                    }
                    .padding(.horizontal, 50)
                    .padding(.vertical, 20)
                }
            }
            .focusSection()
        }
    }
}

/// Smart-Mix-Zeile in Akzentfarbe (wie iOS/Mac). Nativer `.borderedProminent`-Stil:
/// die ganze Pille hebt sich als Einheit beim Fokus — kein separates Icon-Parallax.
private struct MixPill: View {
    let title: String
    let icon: String
    let accent: Color
    let action: () async -> Void

    @State private var loading = false

    var body: some View {
        Button {
            Task { loading = true; await action(); loading = false }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                Text(title).font(.headline)
                Spacer()
                if loading {
                    ProgressView()
                } else {
                    Image(systemName: "play.fill").font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        .disabled(loading)
    }
}
