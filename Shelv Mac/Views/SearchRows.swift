import SwiftUI

struct SearchSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            content
        }
    }
}

struct SearchArtistRow: View {
    let artist: Artist
    var showsDownloadBadge = true
    @State private var isHovered = false
    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(
                coverArtID: artist.coverArt,
                requestSize: 50,
                size: 44,
                isCircle: true
            )
                .padding(.leading, 20)
            VStack(alignment: .leading) {
                Text(artist.name).font(.callout.bold())
                if let count = artist.albumCount {
                    Text(String(format: String(localized: "count_albums_format"), count)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                ArtistFavoriteBadge(artistId: artist.id)
                if showsDownloadBadge {
                    ArtistDownloadBadge(artistName: artist.name, style: .list)
                }
            }
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                .padding(.trailing, 20)
        }
        .padding(.vertical, 4)
        .background { if isHovered { Color.primary.opacity(0.07) } }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

struct SearchAlbumRow: View {
    let album: Album
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(
                coverArtID: album.coverArt,
                requestSize: 50,
                size: 44,
                cornerRadius: 6
            )
                .padding(.leading, 20)
            VStack(alignment: .leading) {
                Text(album.name).font(.callout.bold())
                if let artist = album.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            HStack(spacing: 4) {
                AlbumFavoriteBadge(albumId: album.id)
                AlbumDownloadBadge(albumId: album.id, style: .list)
            }
            if let year = album.year { Text(String(year)).font(.caption).foregroundStyle(.tertiary) }
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                .padding(.trailing, 20)
        }
        .padding(.vertical, 4)
        .background { if isHovered { Color.primary.opacity(0.07) } }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

struct SearchSongRow: View {
    let song: Song
    var showFavorite: Bool = false
    var showPlaylist: Bool = false
    var isStarred: Bool = false
    let onPlay: () -> Void
    var onPlayNext: (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    var onFavorite: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil

    @Environment(\.themeColor) private var themeColor
    private var offlineMode: OfflineModeService { .shared }
    private var showInstantMixActions: Bool {
        UserDefaults.standard.object(forKey: PersonalizationPreferenceKey.showInstantMixActions) as? Bool ?? true
    }
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(
                coverArtID: song.coverArt,
                requestSize: 50,
                size: 44,
                cornerRadius: 6
            )
                .padding(.leading, 20)
            VStack(alignment: .leading) {
                Text(song.title).font(.callout.bold())
                if let artist = song.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            HStack(spacing: 4) {
                SongFavoriteBadge(songId: song.id)
                DownloadStatusIcon(songId: song.id)
            }
            Text(song.durationString).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            Button { onPlay() } label: {
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(themeColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
        }
        .padding(.vertical, 4)
        .background { if isHovered { Color.primary.opacity(0.07) } }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onPlay() }
        .contextMenu {
            Button(String(localized: "play")) { onPlay() }
            if showInstantMixActions && !offlineMode.isOffline {
                Button(String(localized: "instant_mix")) {
                    InstantMixService.playSongMix(for: song)
                }
            }
            Divider()
            if let onPlayNext {
                Button(String(localized: "play_next")) { onPlayNext() }
            }
            if let onAddToQueue {
                Button(String(localized: "add_to_queue")) { onAddToQueue() }
            }
            if showFavorite || showPlaylist {
                Divider()
                if showFavorite, let onFavorite {
                    Button(isStarred
                           ? String(localized: "remove_from_favorites")
                           : String(localized: "add_to_favorites")) {
                        onFavorite()
                    }
                }
                if showPlaylist, let onAddToPlaylist {
                    Button(String(localized: "add_to_playlist")) {
                        onAddToPlaylist()
                    }
                }
            }
            Divider()
            Button(String(localized: "song_info_details")) {
                AppState.shared.showSongInfo(song)
            }
        }
    }
}

struct LyricsSearchRow: View {
    let item: LyricsSearchResult
    let query: String
    var showFavorite: Bool = false
    var showPlaylist: Bool = false
    var isStarred: Bool = false
    let onPlay: () -> Void
    var onPlayNext: (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    var onInstantMix: (() -> Void)? = nil
    var onFavorite: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    @Environment(\.themeColor) private var themeColor
    private var offlineMode: OfflineModeService { .shared }
    private var showInstantMixActions: Bool {
        UserDefaults.standard.object(forKey: PersonalizationPreferenceKey.showInstantMixActions) as? Bool ?? true
    }
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            CoverArtView(
                coverArtID: item.coverArt,
                requestSize: 80,
                size: 44,
                cornerRadius: 6
            )
            .padding(.leading, 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.songTitle ?? String(localized: "unknown_song"))
                    .font(.callout.bold())
                    .foregroundStyle(item.songTitle != nil ? Color.primary : Color.secondary)
                    .lineLimit(1)
                if let artist = item.artistName {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                highlightedLyricsSnippet(
                    item.snippet,
                    query: query,
                    accentColor: themeColor
                )
                    .font(.caption2)
                    .lineLimit(1)
                    .italic()
            }
            Spacer()
            if let dur = item.duration {
                Text(String(format: "%d:%02d", dur / 60, dur % 60))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 4) {
                SongFavoriteBadge(songId: item.songId)
                DownloadStatusIcon(songId: item.songId)
            }
            Button { onPlay() } label: {
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(themeColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
        }
        .padding(.vertical, 4)
        .background { if isHovered { Color.primary.opacity(0.07) } }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onPlay() }
        .contextMenu {
            Button(String(localized: "play")) { onPlay() }
            if showInstantMixActions && !offlineMode.isOffline, let onInstantMix {
                Button(String(localized: "instant_mix")) { onInstantMix() }
            }
            Divider()
            if let onPlayNext {
                Button(String(localized: "play_next")) { onPlayNext() }
            }
            if let onAddToQueue {
                Button(String(localized: "add_to_queue")) { onAddToQueue() }
            }
            if showFavorite || showPlaylist {
                Divider()
                if showFavorite, let onFavorite {
                    Button(isStarred
                           ? String(localized: "remove_from_favorites")
                           : String(localized: "add_to_favorites")) {
                        onFavorite()
                    }
                }
                if showPlaylist, let onAddToPlaylist {
                    Button(String(localized: "add_to_playlist")) { onAddToPlaylist() }
                }
            }
            Divider()
            Button(String(localized: "song_info_details")) {
                AppState.shared.showSongInfo(fallbackSong)
            }
        }
    }

    private var fallbackSong: Song {
        Song(
            id: item.songId,
            title: item.songTitle ?? item.songId,
            artist: item.artistName,
            duration: item.duration,
            coverArt: item.coverArt
        )
    }

    private func highlightedLyricsSnippet(_ snippet: String, query: String, accentColor: Color) -> Text {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty, !needle.isEmpty else {
            return Text(snippet).foregroundStyle(.tertiary)
        }

        var output = Text("")
        var searchStart = snippet.startIndex

        while searchStart < snippet.endIndex,
              let range = snippet.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<snippet.endIndex
              ) {
            if searchStart < range.lowerBound {
                output = output + Text(String(snippet[searchStart..<range.lowerBound]))
                    .foregroundStyle(.tertiary)
            }
            output = output + Text(String(snippet[range]))
                .foregroundStyle(accentColor)
                .bold()
            searchStart = range.upperBound
        }

        if searchStart < snippet.endIndex {
            output = output + Text(String(snippet[searchStart..<snippet.endIndex]))
                .foregroundStyle(.tertiary)
        }

        return output
    }
}
