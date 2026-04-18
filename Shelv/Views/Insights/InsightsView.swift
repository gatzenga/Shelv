import SwiftUI

// MARK: - Internal Models

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

// MARK: - InsightsView

struct InsightsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    // MARK: - Segment

    private enum Segment: Int, CaseIterable {
        case artists, albums, songs
        var label: String {
            switch self {
            case .artists: return tr("Artists", "Künstler")
            case .albums:  return tr("Albums", "Alben")
            case .songs:   return tr("Songs", "Titel")
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
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 12)

                Divider()

                mainContent
            }
            .navigationTitle(tr("Insights", "Insights"))
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .tint(accentColor)
        .task { await loadIfNeeded() }
        .refreshable {
            lastLoadDate = nil
            await loadData(keepExisting: true)
        }
    }

    // MARK: - Main Content

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

    // MARK: - Segment Lists

    @ViewBuilder
    private var artistsListView: some View {
        if topArtists.isEmpty {
            emptyStateView
        } else {
            List {
                ForEach(Array(topArtists.enumerated()), id: \.element.id) { idx, entry in
                    artistRow(rank: idx + 1, entry: entry)
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
                    albumRow(rank: idx + 1, entry: entry)
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
                Text(tr("Loading top songs…", "Lade Top-Titel…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if topSongs.isEmpty {
            emptyStateView
        } else {
            List {
                ForEach(Array(topSongs.enumerated()), id: \.element.id) { idx, song in
                    songRow(rank: idx + 1, song: song)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - State Views

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(tr("Analysing your library…", "Analysiere deine Library…"))
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
            Text(tr("No data available yet", "Noch keine Daten vorhanden"))
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
            Button(tr("Retry", "Wiederholen")) {
                Task { lastLoadDate = nil; await loadData() }
            }
            .buttonStyle(.bordered)
            .tint(accentColor)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row Views

    private func artistRow(rank: Int, entry: TopArtistEntry) -> some View {
        let isTop3 = rank <= 3
        return rankCard(isTop3: isTop3) {
            rankLabel(rank: rank, isTop3: isTop3)
            AlbumArtView(coverArtId: entry.coverArt, size: 100, cornerRadius: 26)
                .frame(width: 52, height: 52)
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
        return rankCard(isTop3: isTop3) {
            rankLabel(rank: rank, isTop3: isTop3)
            AlbumArtView(coverArtId: entry.album.coverArt, size: 100, cornerRadius: 8)
                .frame(width: 52, height: 52)
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
        return rankCard(isTop3: isTop3) {
            rankLabel(rank: rank, isTop3: isTop3)
            AlbumArtView(coverArtId: song.coverArt, size: 100, cornerRadius: 8)
                .frame(width: 52, height: 52)
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

    // MARK: - Shared Components

    private func rankCard<Content: View>(isTop3: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isTop3 ? accentColor.opacity(0.08) : Color(.secondarySystemBackground))
        )
        .overlay {
            if isTop3 {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accentColor.opacity(0.25), lineWidth: 1)
            }
        }
    }

    private func rankLabel(rank: Int, isTop3: Bool) -> some View {
        Text("\(rank)")
            .font(isTop3 ? .title2.bold() : .callout.bold())
            .foregroundStyle(isTop3 ? accentColor : Color.secondary)
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
        .foregroundStyle(isTop3 ? accentColor : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isTop3 ? accentColor : Color.secondary).opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Data Loading

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
            let frequentAlbums = try await SubsonicAPIService.shared.getAlbumList(type: "frequent", size: 500)

            // Top Albums — sort by playCount, take top 20
            let sortedAlbums = frequentAlbums.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
            topAlbums = sortedAlbums.prefix(20).map { TopAlbumEntry(album: $0, playCount: $0.playCount ?? 0) }

            // Top Artists — group by artistId, sum playCount, take top 20
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
                let name = album.artist ?? tr("Unknown Artist", "Unbekannter Künstler")
                guard !excludedArtistNames.contains(name.lowercased()) else { continue }
                let pc = album.playCount ?? 0
                if let ex = artistMap[aid] {
                    artistMap[aid] = (ex.name, ex.coverArt, ex.total + pc)
                } else {
                    // Verwende artistId als coverArt-ID — Navidrome liefert damit das Künstlerbild
                    artistMap[aid] = (name, album.artistId, pc)
                }
            }
            topArtists = artistMap
                .map { TopArtistEntry(id: $0.key, name: $0.value.name, coverArt: $0.value.coverArt, totalPlayCount: $0.value.total) }
                .sorted { $0.totalPlayCount > $1.totalPlayCount }
                .prefix(20)
                .map { $0 }

            isLoading = false
            lastLoadDate = Date()

            // Progressive: songs load after artists/albums are already visible
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

            let songs = try await withThrowingTaskGroup(of: [Song].self) { group in
                for album in filtered {
                    group.addTask {
                        (try await SubsonicAPIService.shared.getAlbum(id: album.id)).song ?? []
                    }
                }
                var all: [Song] = []
                for try await albumSongs in group { all.append(contentsOf: albumSongs) }
                return all
            }
            topSongs = songs
                .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
                .prefix(20)
                .map { $0 }
        } catch {
            // Silent fail — user kann per Pull-to-Refresh neu laden
        }
    }
}
