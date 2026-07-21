import SwiftUI
@preconcurrency import Combine

/// Favoritenstatus mit denselben Maßen wie der jeweilige Downloadstatus.
struct FavoriteAvailabilityIcon: View {
    var style: DownloadIndicatorStyle = .list
    @AppStorage("themeColor") private var themeColorName = "violet"

    var body: some View {
        Group {
            switch style {
            case .list:
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.color(for: themeColorName))
                    .frame(width: 14, height: 14)
            case .cover:
                Image(systemName: "heart.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.color(for: themeColorName))
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityLabel(String(localized: "favorite"))
    }
}

struct AlbumFavoriteBadge: View {
    let albumId: String
    var style: DownloadIndicatorStyle = .list
    private let libraryStore = LibraryStore.shared
    @State private var isFavorite: Bool

    init(albumId: String, style: DownloadIndicatorStyle = .list) {
        self.albumId = albumId
        self.style = style
        _isFavorite = State(
            initialValue: LibraryStore.shared.starredAlbums.contains { $0.id == albumId }
        )
    }

    var body: some View {
        Group {
            if isFavorite {
                FavoriteAvailabilityIcon(style: style)
            }
        }
        .onReceive(
            libraryStore.$starredAlbums
                .map { albums in albums.contains { $0.id == albumId } }
                .removeDuplicates()
        ) { isFavorite = $0 }
    }
}

struct ArtistFavoriteBadge: View {
    let artistId: String
    var style: DownloadIndicatorStyle = .list
    private let libraryStore = LibraryStore.shared
    @State private var isFavorite: Bool

    init(artistId: String, style: DownloadIndicatorStyle = .list) {
        self.artistId = artistId
        self.style = style
        _isFavorite = State(
            initialValue: LibraryStore.shared.starredArtists.contains { $0.id == artistId }
        )
    }

    var body: some View {
        Group {
            if isFavorite {
                FavoriteAvailabilityIcon(style: style)
            }
        }
        .onReceive(
            libraryStore.$starredArtists
                .map { artists in artists.contains { $0.id == artistId } }
                .removeDuplicates()
        ) { isFavorite = $0 }
    }
}

struct SongFavoriteBadge: View {
    let songId: String
    var style: DownloadIndicatorStyle = .list
    private let libraryStore = LibraryStore.shared
    @State private var isFavorite: Bool

    init(songId: String, style: DownloadIndicatorStyle = .list) {
        self.songId = songId
        self.style = style
        _isFavorite = State(
            initialValue: LibraryStore.shared.starredSongs.contains { $0.id == songId }
        )
    }

    var body: some View {
        Group {
            if isFavorite {
                FavoriteAvailabilityIcon(style: style)
            }
        }
        .onReceive(
            libraryStore.$starredSongs
                .map { songs in songs.contains { $0.id == songId } }
                .removeDuplicates()
        ) { isFavorite = $0 }
    }
}
