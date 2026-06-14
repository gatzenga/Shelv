import SwiftUI

struct DiscoverView: View {
    @ObservedObject var library = LibraryStore.shared
    @AppStorage("mixUseDatabase") private var mixUseDatabase = false
    @AppStorage("themeColor") private var themeColor = "violet"
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

    private var accent: Color { AppTheme.color(for: themeColor) }

    @State private var newest: [Album] = []
    @State private var recent: [Album] = []
    @State private var frequent: [Album] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    // Links Refresh (Reload + iCloud-Sync inkl. Queue-Check), rechts Insights.
                    HStack {
                        Button {
                            // Wie der Mac-Refresh: Server neu kontaktieren (Discover + Playlists)
                            // und iCloud-Sync inkl. Queue-Check.
                            Task {
                                async let discover:  Void = load()
                                async let playlists: Void = LibraryStore.shared.loadPlaylists()
                                async let sync:      Void = CloudKitSyncService.shared.syncNow()
                                _ = await (discover, playlists, sync)
                            }
                        } label: {
                            Label(String(localized: "refresh"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        NavigationLink { InsightsView() } label: {
                            Label(String(localized: "insights"), systemImage: "chart.bar.xaxis")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 50)
                    .focusSection()

                    // Smart-Mixe als saubere Akzent-Liste über die volle Breite (wie iOS/Mac)
                    VStack(spacing: 16) {
                        MixPill(title: String(localized: "mix_newest_tracks"), icon: "sparkles", accent: accent) { await play(.newest) }
                        MixPill(title: String(localized: "mix_frequently_played"), icon: "chart.bar.fill", accent: accent) { await play(.frequent) }
                        MixPill(title: String(localized: "mix_recently_played"), icon: "clock.fill", accent: accent) { await play(.recent) }
                        MixPill(title: String(localized: "mix_shuffle_all"), icon: "shuffle", accent: accent) { await play(.random) }
                    }
                    .padding(.horizontal, 50)
                    .focusSection()

                    albumRow(String(localized: "recently_added"), newest)
                    albumRow(String(localized: "recently_played"), recent)
                    albumRow(String(localized: "frequently_played"), frequent)
                }
                .padding(.vertical, 50)
            }
            .task(id: library.reloadID) { await load() }
        }
    }

    // MARK: - Daten

    private func load() async {
        async let n = try? api.getAlbumList(type: "newest", size: 20)
        async let r = try? api.getAlbumList(type: "recent", size: 20)
        async let f = try? api.getAlbumList(type: "frequent", size: 20)
        newest = await n ?? []
        recent = await r ?? []
        frequent = await f ?? []
    }

    private enum Mix { case newest, frequent, recent, random }

    private func play(_ mix: Mix) async {
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
        let albums = (try? await api.getAlbumList(type: "frequent", size: 100)) ?? []
        var out: [Song] = []
        for a in albums.prefix(20) { out += (try? await api.getAlbum(id: a.id).song) ?? [] }
        return out
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
