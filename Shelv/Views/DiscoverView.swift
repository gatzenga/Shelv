import SwiftUI

struct DiscoverView: View {
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @EnvironmentObject var recapStore: RecapStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("mixUseDatabase") private var mixUseDatabase = false
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var recapButtonVisible: Bool {
        // Wenn Recap deaktiviert ist, soll der Eintrag komplett aus der UI verschwinden.
        guard recapEnabled else { return false }
        if !offlineMode.isOffline { return true }
        // Offline: nur wenn mindestens eine Recap-Playlist heruntergeladen ist.
        return !recapStore.recapPlaylistIds.isDisjoint(with: downloadStore.offlinePlaylistIds)
    }

    @State private var mixLoading: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var randomRefreshing = false
    @State private var showInsights = false
    @State private var showRecap = false
    @State private var showOfflineHint = false
    @State private var refreshContinuation: CheckedContinuation<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if offlineMode.isOffline {
                        if downloadStore.songs.isEmpty {
                            offlineEmptyState
                        } else {
                            offlineMixState
                        }
                    } else if libraryStore.isLoadingDiscover && libraryStore.recentlyAdded.isEmpty {
                        VStack(spacing: 20) {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                            if showOfflineHint {
                                Button {
                                    offlineMode.enterOfflineMode()
                                } label: {
                                    Label(String(localized: "go_offline"), systemImage: "wifi.slash")
                                        .font(.subheadline.bold())
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 10)
                                        .background(accentColor.opacity(0.15))
                                        .clipShape(Capsule())
                                        .foregroundStyle(accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 60)
                    } else {
                        VStack(spacing: 12) {
                            mixButton(
                                title: String(localized: "mix_newest_tracks"),
                                icon: "sparkles",
                                key: "newest"
                            ) { await loadMix(type: "newest") }

                            mixButton(
                                title: String(localized: "mix_frequently_played"),
                                icon: "chart.bar.fill",
                                key: "frequent"
                            ) { await loadMix(type: "frequent") }

                            mixButton(
                                title: String(localized: "mix_recently_played"),
                                icon: "clock.fill",
                                key: "recent"
                            ) { await loadMix(type: "recent") }

                            mixButton(
                                title: String(localized: "mix_shuffle_all"),
                                icon: "shuffle",
                                key: "random"
                            ) { await loadMix(type: "random") }
                        }
                        .padding(.horizontal)

                        albumSection(
                            title: String(localized: "recently_added"),
                            albums: libraryStore.recentlyAdded
                        )
                        albumSection(
                            title: String(localized: "recently_played"),
                            albums: libraryStore.recentlyPlayed
                        )
                        albumSection(
                            title: String(localized: "frequently_played"),
                            albums: libraryStore.frequentlyPlayed
                        )
                        randomAlbumSection

                        PlayerBottomSpacer()
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Shelv")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if recapButtonVisible {
                            Button {
                                showRecap = true
                            } label: {
                                Image(systemName: "calendar.badge.clock")
                            }
                        }
                        if !offlineMode.isOffline {
                            Button {
                                showInsights = true
                            } label: {
                                Image(systemName: "chart.bar.xaxis")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showInsights) {
                InsightsView()
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .sheet(isPresented: $showRecap) {
                RecapView()
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .refreshable {
                await withCheckedContinuation { cont in
                    refreshContinuation = cont
                    Task { @MainActor in
                        async let discover: Void = libraryStore.loadDiscover()
                        async let random:   Void = libraryStore.refreshRandomAlbums()
                        async let sync:     Void = CloudKitSyncService.shared.syncNow()
                        _ = await (discover, random, sync)
                        if let cont = refreshContinuation {
                            refreshContinuation = nil
                            cont.resume()
                        }
                    }
                }
            }
            .task(id: libraryStore.reloadID) {
                await libraryStore.loadDiscover()
            }
            .task(id: libraryStore.isLoadingDiscover) {
                showOfflineHint = false
                guard libraryStore.isLoadingDiscover && libraryStore.recentlyAdded.isEmpty else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                showOfflineHint = libraryStore.isLoadingDiscover && libraryStore.recentlyAdded.isEmpty
            }
            .onChange(of: offlineMode.isOffline) { _, isOffline in
                if isOffline {
                    if let cont = refreshContinuation {
                        refreshContinuation = nil
                        cont.resume()
                    }
                } else {
                    Task { await libraryStore.loadDiscover() }
                }
            }
            .alert(String(localized: "error"), isPresented: $showError, presenting: errorMessage) { _ in
                Button(String(localized: "ok"), role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
        }
    }

    @ViewBuilder
    private var offlineEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text(String(localized: "you_are_offline"))
                .font(.title3).bold()
            Text(String(localized: "downloads_are_still_available_tap_the_magnifying_g"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            Button {
                offlineMode.exitOfflineMode()
            } label: {
                Label(String(localized: "go_online"), systemImage: "wifi")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundStyle(accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private var offlineMixState: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                mixButton(
                    title: String(localized: "play_all_downloads"),
                    icon: "play.fill",
                    key: "offline_play"
                ) { loadOfflineMix(type: "offline_play") }

                mixButton(
                    title: String(localized: "shuffle_all_downloads"),
                    icon: "shuffle",
                    key: "offline_shuffle"
                ) { loadOfflineMix(type: "offline_shuffle") }

                mixButton(
                    title: String(localized: "mix_latest_downloads"),
                    icon: "arrow.down.circle.fill",
                    key: "offline_newest"
                ) { loadOfflineMix(type: "offline_newest") }
            }
            .padding(.horizontal)

            HStack {
                Spacer()
                Button {
                    offlineMode.exitOfflineMode()
                } label: {
                    Label(String(localized: "go_online"), systemImage: "wifi")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(accentColor.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var randomAlbumSection: some View {
        albumSection(title: String(localized: "random_albums"), albums: libraryStore.randomAlbums) {
            Button {
                randomRefreshing = true
                Task {
                    await libraryStore.refreshRandomAlbums()
                    randomRefreshing = false
                }
            } label: {
                Image(systemName: "shuffle")
                    .font(.body)
                    .foregroundStyle(accentColor)
                    .rotationEffect(.degrees(randomRefreshing ? 360 : 0))
                    .animation(
                        randomRefreshing ? .linear(duration: 0.5).repeatForever(autoreverses: false) : .default,
                        value: randomRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(randomRefreshing)
        }
    }

    @ViewBuilder
    private func albumSection<T: View>(title: String, albums: [Album], @ViewBuilder trailingButton: () -> T = { EmptyView() }) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(.title3).bold()
                    Spacer()
                    trailingButton()
                }
                .padding(.horizontal)

                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCardView(album: album, fixedSize: 140, showArtist: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    private func mixButton(
        title: String,
        icon: String,
        key: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task {
                mixLoading = key
                await action()
                mixLoading = nil
            }
        } label: {
            HStack {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 28)
                Text(title)
                    .font(.body).bold()
                Spacer()
                if mixLoading == key {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(accentColor)
            .clipShape(Capsule())
        }
        .disabled(mixLoading != nil)
    }

    private func loadOfflineMix(type: String) {
        let allSongs = downloadStore.songs.map { $0.asSong() }
        guard !allSongs.isEmpty else { return }

        switch type {
        case "offline_play":
            let sorted = allSongs.sorted {
                let a = stripArticle($0.artist ?? "")
                    .localizedStandardCompare(stripArticle($1.artist ?? ""))
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

    private func loadMix(type: String) async {
        do {
            let songs: [Song]
            switch type {
            case "newest":   songs = try await SubsonicAPIService.shared.getNewestSongs()
            case "frequent": songs = try await frequentMixSongs()
            case "random":   songs = try await SubsonicAPIService.shared.getRandomSongs(size: 500)
            default:
                songs = try await recentMixSongs()
            }
            player.playShuffled(songs: songs)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func frequentMixSongs() async throws -> [Song] {
        // Toggle aktiv UND genug DB-Daten (≥ 50 einzigartige Songs) → lokale Play-Log-DB.
        // Sonst serverseitig (Navidrome-Frequenzdaten, wie Insights).
        if mixUseDatabase,
           let serverId = SubsonicAPIService.shared.activeServer?.stableId,
           await PlayLogService.shared.distinctSongCount(serverId: serverId) >= 50 {
            let counts = await PlayLogService.shared.topSongs(
                serverId: serverId, from: .distantPast, to: Date(), limit: 50)
            if !counts.isEmpty {
                return try await SubsonicAPIService.shared.getSongsOrdered(ids: counts.map(\.songId))
            }
        }
        return try await frequentFallbackSongs()
    }

    /// Server-Methode (wie Insights): Top-500-Alben, dynamischer Schwellenwert, Top 50 Songs nach Playcount.
    private func frequentFallbackSongs() async throws -> [Song] {
        let allFrequent = try await SubsonicAPIService.shared.getAlbumList(type: "frequent", size: 500)
        let sorted = allFrequent.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        let maxPC = sorted.first?.playCount ?? 0
        let threshold = max(maxPC / 50, 1)
        var filtered = sorted.filter { ($0.playCount ?? 0) >= threshold }
        if filtered.count < 30 { filtered = Array(sorted.prefix(30)) }
        if filtered.count > 80 { filtered = Array(sorted.prefix(80)) }
        let songs = try await withThrowingTaskGroup(of: [Song].self) { group in
            for album in filtered {
                group.addTask { (try? await SubsonicAPIService.shared.getAlbum(id: album.id))?.song ?? [] }
            }
            var all: [Song] = []
            for try await albumSongs in group { all.append(contentsOf: albumSongs) }
            return all
        }
        return Array(songs.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(50))
    }

    private func recentMixSongs() async throws -> [Song] {
        // Toggle aktiv UND genug DB-Daten → echte zuletzt gehörte Songs aus der DB.
        // Sonst serverseitig (album-basiert über getRecentSongs).
        if mixUseDatabase,
           let serverId = SubsonicAPIService.shared.activeServer?.stableId,
           await PlayLogService.shared.distinctSongCount(serverId: serverId) >= 50 {
            let ids = await PlayLogService.shared.recentUniqueSongIds(serverId: serverId, limit: 50)
            if !ids.isEmpty {
                return try await SubsonicAPIService.shared.getSongsOrdered(ids: ids)
            }
        }
        return try await SubsonicAPIService.shared.getRecentSongs(limit: 50)
    }
}
