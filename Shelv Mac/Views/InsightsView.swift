import SwiftUI

private struct TopArtistEntry: Identifiable {
    let id: String
    let name: String
    let coverArt: String?
    let totalPlayCount: Int
}

private struct TopAlbumEntry: Identifiable {
    var id: String { album.id }
    let album: Album
    let playCount: Int
}

struct InsightsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.themeColor) private var themeColor
    @Environment(\.dismiss) private var dismiss

    private enum Segment: Int, CaseIterable {
        case artists, albums, songs
        var label: String {
            switch self {
            case .artists: return String(localized: "artists")
            case .albums:  return String(localized: "albums")
            case .songs:   return String(localized: "songs")
            }
        }
    }

    @State private var segment: Segment = .artists
    @State private var isLoading = false
    @State private var songsLoading = false
    @State private var topArtists: [TopArtistEntry] = []
    @State private var topAlbums: [TopAlbumEntry] = []
    @State private var topSongs: [Song] = []
    @State private var errorMessage: String?
    @State private var lastLoadDate: Date?

    private let cacheSeconds: Double = 30 * 60

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    Task { lastLoadDate = nil; await loadData(keepExisting: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help(String(localized: "reload"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 580)
        .task { await loadIfNeeded() }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let err = errorMessage {
            errorView(err)
        } else if isLoading && topArtists.isEmpty {
            loadingView
        } else {
            switch segment {
            case .artists: artistsListView
            case .albums:  albumsListView
            case .songs:   songsListView
            }
        }
    }

    @ViewBuilder
    private var artistsListView: some View {
        if topArtists.isEmpty {
            emptyStateView
        } else {
            List {
                ForEach(Array(topArtists.enumerated()), id: \.element.id) { idx, entry in
                    Button {
                        openArtist(entry)
                    } label: {
                        artistRow(rank: idx + 1, entry: entry)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var albumsListView: some View {
        if topAlbums.isEmpty {
            emptyStateView
        } else {
            List {
                ForEach(Array(topAlbums.enumerated()), id: \.element.id) { idx, entry in
                    Button {
                        openAlbum(entry.album)
                    } label: {
                        albumRow(rank: idx + 1, entry: entry)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var songsListView: some View {
        if songsLoading && topSongs.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                Text(String(localized: "loading_top_songs"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if topSongs.isEmpty {
            emptyStateView
        } else {
            List {
                ForEach(Array(topSongs.enumerated()), id: \.element.id) { idx, song in
                    Button {
                        AudioPlayerService.shared.play(songs: topSongs, startIndex: idx)
                    } label: {
                        songRow(rank: idx + 1, song: song)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
        }
    }

    private func openArtist(_ entry: TopArtistEntry) {
        appState.selectedPlaylist = nil
        appState.selectedSidebar = .artists
        appState.navigationPath = NavigationPath()
        appState.navigationPath.append(
            Artist(id: entry.id, name: entry.name, albumCount: nil, coverArt: entry.coverArt, starred: nil)
        )
    }

    private func openAlbum(_ album: Album) {
        appState.selectedPlaylist = nil
        appState.selectedSidebar = .albums
        appState.navigationPath = NavigationPath()
        appState.navigationPath.append(album)
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(String(localized: "analysing_your_library"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text(String(localized: "no_data_available_yet"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "retry")) {
                Task { lastLoadDate = nil; await loadData() }
            }
            .buttonStyle(.bordered)
            .tint(themeColor)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func artistRow(rank: Int, entry: TopArtistEntry) -> some View {
        let isTop3 = rank <= 3
        let url = entry.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 100) }
        return rankCard(isTop3: isTop3) {
            rankLabel(rank: rank, isTop3: isTop3)
            CoverArtView(url: url, size: 52, isCircle: true)
            Text(entry.name)
                .font(isTop3 ? .body.bold() : .body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            playCountBadge(entry.totalPlayCount, isTop3: isTop3)
        }
    }

    private func albumRow(rank: Int, entry: TopAlbumEntry) -> some View {
        let isTop3 = rank <= 3
        let url = entry.album.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 100) }
        return rankCard(isTop3: isTop3) {
            rankLabel(rank: rank, isTop3: isTop3)
            CoverArtView(url: url, size: 52, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.album.name)
                    .font(isTop3 ? .body.bold() : .body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let artist = entry.album.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            playCountBadge(entry.playCount, isTop3: isTop3)
        }
    }

    private func songRow(rank: Int, song: Song) -> some View {
        let isTop3 = rank <= 3
        let url = song.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 100) }
        return rankCard(isTop3: isTop3) {
            rankLabel(rank: rank, isTop3: isTop3)
            CoverArtView(url: url, size: 52, cornerRadius: 8)
                .overlay {
                    NowPlayingOverlay(songId: song.id, size: 52, cornerRadius: 8)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(isTop3 ? .body.bold() : .body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let pc = song.playCount {
                playCountBadge(pc, isTop3: isTop3)
            }
        }
    }

    private func rankCard<Content: View>(isTop3: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.vertical, isTop3 ? 10 : 6)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isTop3 ? themeColor.opacity(0.08) : Color(NSColor.controlBackgroundColor))
        )
        .overlay {
            if isTop3 {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(themeColor.opacity(0.25), lineWidth: 1)
            }
        }
    }

    private func rankLabel(rank: Int, isTop3: Bool) -> some View {
        Text("\(rank)")
            .font(isTop3 ? .title2.bold() : .callout.bold())
            .foregroundStyle(isTop3 ? themeColor : Color.secondary)
            .monospacedDigit()
            .frame(width: 28, alignment: .trailing)
    }

    private func playCountBadge(_ count: Int, isTop3: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.caption2)
            Text("\(count)")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(isTop3 ? themeColor : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isTop3 ? themeColor : Color.secondary).opacity(0.12))
        .clipShape(Capsule())
    }

    private func loadIfNeeded() async {
        guard !isLoading else { return }
        if let last = lastLoadDate, Date().timeIntervalSince(last) < cacheSeconds { return }
        await loadData()
    }

    private func loadData(keepExisting: Bool = false) async {
        isLoading = true
        errorMessage = nil
        if !keepExisting {
            topArtists = []
            topAlbums = []
            topSongs = []
        }

        do {
            let frequentAlbums = try await SubsonicAPIService.shared.getAlbumList(type: .frequent, size: 500)

            let sortedAlbums = frequentAlbums.sorted {
                let a = $0.playCount ?? 0, b = $1.playCount ?? 0
                return a != b ? a > b : $0.id < $1.id
            }
            topAlbums = sortedAlbums.prefix(20).map { TopAlbumEntry(album: $0, playCount: $0.playCount ?? 0) }

            let excludedArtistNames: Set<String> = [
                "various artists", "various artist", "various", "va", "v.a.", "v/a",
                "diverse", "divers", "sampler", "compilation", "compilations",
                "verschiedene künstler", "verschiedene", "mehrere interpreten",
                "artistas varios", "varios artistas", "artistes variés",
                "unknown artist", "unbekannter künstler", "unknown", "unbekannt"
            ]
            var artistMap: [String: (name: String, coverArt: String?, total: Int)] = [:]
            for album in frequentAlbums {
                let aid  = album.artistId ?? "_\(album.artist ?? "unknown")"
                let name = album.artist ?? String(localized: "unknown_artist")
                guard !excludedArtistNames.contains(name.lowercased()) else { continue }
                let pc = album.playCount ?? 0
                if let ex = artistMap[aid] {
                    artistMap[aid] = (ex.name, ex.coverArt, ex.total + pc)
                } else {
                    artistMap[aid] = (name, album.artistId, pc)
                }
            }
            topArtists = artistMap
                .map { TopArtistEntry(id: $0.key, name: $0.value.name, coverArt: $0.value.coverArt, totalPlayCount: $0.value.total) }
                .sorted {
                    $0.totalPlayCount != $1.totalPlayCount
                        ? $0.totalPlayCount > $1.totalPlayCount
                        : $0.id < $1.id
                }
                .prefix(20)
                .map { $0 }

            isLoading = false
            lastLoadDate = Date()

            await loadTopSongs(from: frequentAlbums)
        } catch {
            let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !isCancelled {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func loadTopSongs(from frequentAlbums: [Album]) async {
        songsLoading = true
        defer { songsLoading = false }

        do {
            let sorted    = frequentAlbums.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
            let maxPC     = sorted.first?.playCount ?? 0
            let threshold = max(maxPC / 50, 1)

            var filtered = sorted.filter { ($0.playCount ?? 0) >= threshold }
            if filtered.count < 30 { filtered = Array(sorted.prefix(30)) }
            if filtered.count > 80 { filtered = Array(sorted.prefix(80)) }

            let songs = try await withThrowingTaskGroup(of: [Song].self) { group -> [Song] in
                for album in filtered {
                    group.addTask {
                        try await SubsonicAPIService.shared.getAlbum(id: album.id).song ?? []
                    }
                }
                var all: [Song] = []
                for try await albumSongs in group { all.append(contentsOf: albumSongs) }
                return all
            }
            topSongs = songs
                .sorted {
                    let a = $0.playCount ?? 0, b = $1.playCount ?? 0
                    return a != b ? a > b : $0.id < $1.id
                }
                .prefix(20)
                .map { $0 }
        } catch {
        }
    }
}
