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
                    // Insights als kleiner Button in der Ecke
                    HStack {
                        Spacer()
                        NavigationLink { InsightsView() } label: {
                            Image(systemName: "chart.bar.xaxis").font(.title2)
                        }
                        .buttonStyle(.borderless)
                    }

                    // Smart-Mixe als Akzent-Pillen (wie iOS/Mac)
                    VStack(spacing: 16) {
                        MixPill(title: String(localized: "mix_newest_tracks"), icon: "sparkles", accent: accent) { await play(.newest) }
                        MixPill(title: String(localized: "mix_frequently_played"), icon: "chart.bar.fill", accent: accent) { await play(.frequent) }
                        MixPill(title: String(localized: "mix_recently_played"), icon: "clock.fill", accent: accent) { await play(.recent) }
                        MixPill(title: String(localized: "mix_shuffle_all"), icon: "shuffle", accent: accent) { await play(.random) }
                    }
                    .frame(maxWidth: 820)

                    albumRow(String(localized: "recently_added"), newest)
                    albumRow(String(localized: "recently_played"), recent)
                    albumRow(String(localized: "frequently_played"), frequent)
                }
                .padding(50)
            }
            .scrollClipDisabled()
            .task { await load() }
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

    @ViewBuilder
    private func albumRow(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title2).bold()
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 40) {
                        ForEach(albums) { AlbumCard(album: $0, size: 240) }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// Smart-Mix-Zeile in Akzentfarbe (wie iOS/Mac) — fokussierbar mit dezentem Zoom.
private struct MixPill: View {
    let title: String
    let icon: String
    let accent: Color
    let action: () async -> Void

    @FocusState private var focused: Bool
    @State private var loading = false

    var body: some View {
        Button {
            Task { loading = true; await action(); loading = false }
        } label: {
            HStack(spacing: 18) {
                Image(systemName: icon).frame(width: 32)
                Text(title).font(.title3).bold()
                Spacer()
                if loading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "play.fill").font(.callout)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background(accent)
            .clipShape(Capsule())
            .scaleEffect(focused ? 1.03 : 1.0)
            .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 14, y: 6)
            .animation(.easeOut(duration: 0.15), value: focused)
        }
        .buttonStyle(.borderless)
        .focused($focused)
        .disabled(loading)
    }
}
