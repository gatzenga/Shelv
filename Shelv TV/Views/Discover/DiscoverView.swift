import SwiftUI

struct DiscoverView: View {
    @ObservedObject var library = LibraryStore.shared
    @AppStorage("mixUseDatabase") private var mixUseDatabase = false
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

    @State private var newest: [Album] = []
    @State private var recent: [Album] = []
    @State private var frequent: [Album] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    // Smart-Mixe + Insights-Ecke
                    HStack(alignment: .top, spacing: 24) {
                        mixButton(String(localized: "mix_newest_tracks"), "sparkles") { await play(.newest) }
                        mixButton(String(localized: "mix_frequently_played"), "flame") { await play(.frequent) }
                        mixButton(String(localized: "mix_recently_played"), "clock") { await play(.recent) }
                        mixButton(String(localized: "mix_shuffle_all"), "shuffle") { await play(.random) }
                        Spacer()
                        NavigationLink { InsightsView() } label: {
                            Image(systemName: "chart.bar.xaxis").font(.title2)
                        }
                    }

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

    private func mixButton(_ title: String, _ icon: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            VStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 40))
                Text(title).font(.callout).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(width: 260, height: 180)
        }
        .buttonStyle(.card)
    }

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
