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

/// Insights wie iOS: segmentiert nach Künstler / Alben / Songs, jeweils als
/// gerankte Liste mit Playcount. Rein serverbasiert (frequent-Alben), keine DB nötig.
struct InsightsView: View {
    @AppStorage("themeColor") private var themeColor = "violet"
    @ObservedObject private var library = LibraryStore.shared
    private var accent: Color { AppTheme.color(for: themeColor) }
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

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
    @State private var topArtists: [TopArtistEntry] = []
    @State private var topAlbums: [TopAlbumEntry] = []
    @State private var topSongs: [Song] = []
    @State private var isLoading = true
    @State private var navAlbum: Album?
    @State private var navArtist: Artist?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 700)
            .padding(.top, 40)
            .padding(.bottom, 24)

            if isLoading && topArtists.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        switch segment {
                        case .artists:
                            ForEach(Array(topArtists.enumerated()), id: \.element.id) { i, e in
                                InsightsRow { navArtist = libraryArtist(for: e) } content: {
                                    row(rank: i + 1, url: artistCoverURL(for: e),
                                        isCircle: true, title: e.name, subtitle: nil, plays: e.totalPlayCount)
                                }
                            }
                        case .albums:
                            ForEach(Array(topAlbums.enumerated()), id: \.element.id) { i, e in
                                InsightsRow { navAlbum = e.album } content: {
                                    row(rank: i + 1, url: e.album.coverURL(200), isCircle: false,
                                        title: e.album.name, subtitle: e.album.artist, plays: e.playCount)
                                }
                            }
                        case .songs:
                            ForEach(Array(topSongs.enumerated()), id: \.element.id) { i, song in
                                InsightsRow { player.play(songs: topSongs, startIndex: i) } content: {
                                    row(rank: i + 1, url: song.coverURL(200), isCircle: false,
                                        title: song.title, subtitle: song.artist, plays: song.playCount ?? 0)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationDestination(item: $navAlbum) { AlbumDetailView(album: $0) }
        .navigationDestination(item: $navArtist) { ArtistDetailView(artist: $0) }
        .task(id: library.reloadID) {
            if InsightsCache.isFresh(for: library.reloadID) {
                topArtists = InsightsCache.artists
                topAlbums = InsightsCache.albums
                topSongs = InsightsCache.songs
                isLoading = false
                return
            }
            isLoading = true
            async let artists: Void = LibraryStore.shared.loadArtists()   // fürs Künstler-Matching
            await load()
            _ = await artists
        }
    }

    // MARK: - Künstler-Auflösung

    /// Echtes Library-Artist-Objekt (für Navigation + Bild); Fallback: aus dem Eintrag konstruiert.
    private func libraryArtist(for entry: TopArtistEntry) -> Artist {
        LibraryStore.shared.artists.first { $0.id == entry.id || $0.name == entry.name }
            ?? Artist(id: entry.id, name: entry.name, coverArt: entry.coverArt)
    }

    private func artistCoverURL(for entry: TopArtistEntry) -> URL? {
        let artist = libraryArtist(for: entry)
        if let url = artist.coverURL(200) { return url }
        return entry.coverArt.flatMap { api.coverArtURL(for: $0, size: 200) }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(rank: Int, url: URL?, isCircle: Bool, title: String, subtitle: String?, plays: Int) -> some View {
        let isTop3 = rank <= 3
        HStack(spacing: 20) {
            Text("\(rank)")
                .font(isTop3 ? .title3.bold() : .body)
                .foregroundStyle(isTop3 ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            CoverArtView(url: url, size: 80,
                         cornerRadius: isCircle ? 40 : 8, isCircle: isCircle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(isTop3 ? .title3.bold() : .title3).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.caption)
                Text("\(plays)").font(.callout.monospacedDigit())
            }
            .foregroundStyle(isTop3 ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
        }
    }

    // MARK: - Daten (portiert aus iOS)

    private func load() async {
        guard let frequent = try? await api.getAlbumList(type: "frequent", size: 500) else {
            isLoading = false; return
        }

        topAlbums = frequent
            .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
            .prefix(20)
            .map { TopAlbumEntry(album: $0, playCount: $0.playCount ?? 0) }

        let excluded: Set<String> = [
            "various artists", "various artist", "various", "va", "v.a.", "v/a",
            "diverse", "divers", "sampler", "compilation", "compilations",
            "verschiedene künstler", "verschiedene", "unknown artist", "unbekannt"
        ]
        var map: [String: (name: String, cover: String?, total: Int)] = [:]
        for album in frequent {
            let name = album.artist ?? String(localized: "unknown_artist")
            guard !excluded.contains(name.lowercased()) else { continue }
            let aid = album.artistId ?? "_\(name)"
            let pc = album.playCount ?? 0
            if let ex = map[aid] {
                map[aid] = (ex.name, ex.cover, ex.total + pc)
            } else {
                map[aid] = (name, album.artistId, pc)
            }
        }
        topArtists = map
            .map { TopArtistEntry(id: $0.key, name: $0.value.name, coverArt: $0.value.cover, totalPlayCount: $0.value.total) }
            .sorted { $0.totalPlayCount > $1.totalPlayCount }
            .prefix(20).map { $0 }

        InsightsCache.albums = topAlbums
        InsightsCache.artists = topArtists
        isLoading = false
        await loadTopSongs(from: frequent)
        // Cache erst jetzt als „frisch" markieren — sonst gilt er mit leeren Songs als gültig
        // und das Songs-Segment bliebe bis zum Ablauf leer (Songs werden erst hier befüllt).
        InsightsCache.reloadID = library.reloadID
        InsightsCache.timestamp = Date()
    }

    private func loadTopSongs(from frequent: [Album]) async {
        let sorted = frequent.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        var pool = Array(sorted.prefix(80))
        if pool.isEmpty { pool = sorted }

        let songs = await withTaskGroup(of: [Song].self) { group in
            for album in pool {
                group.addTask { (try? await self.api.getAlbum(id: album.id))?.song ?? [] }
            }
            var all: [Song] = []
            for await s in group { all += s }
            return all
        }
        topSongs = songs
            .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
            .prefix(20).map { $0 }
        InsightsCache.songs = topSongs
    }
}

/// Gerankte Insights-Zeile im einheitlichen borderless-Akzent-Fokus-Stil.
private struct InsightsRow<Content: View>: View {
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().rowButton(action: onSelect)
    }
}

/// 30-Minuten-Cache für Insights — verhindert Neuladen bei jedem Öffnen.
@MainActor
private enum InsightsCache {
    static var artists: [TopArtistEntry] = []
    static var albums: [TopAlbumEntry] = []
    static var songs: [Song] = []
    static var timestamp: Date?
    /// reloadID, unter der gecacht wurde — bei Server-Wechsel wechselt sie, Cache wird ungültig.
    static var reloadID: UUID?
    static func isFresh(for reloadID: UUID) -> Bool {
        guard let t = timestamp, self.reloadID == reloadID, !artists.isEmpty else { return false }
        return Date().timeIntervalSince(t) < 30 * 60
    }
}
