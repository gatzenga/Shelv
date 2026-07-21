import SwiftUI
@preconcurrency import Combine

private struct CoverStatusCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5)
                }
                .padding(.horizontal, -7)
                .padding(.vertical, -5)
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
    }
}

extension View {
    func coverStatusCapsule() -> some View {
        modifier(CoverStatusCapsuleModifier())
    }
}

enum FavoriteIndicatorStyle {
    case list
    case cover
}

/// tvOS-Favoritenstatus: kompakt in Listen und größer auf Cover-Artwork.
struct FavoriteAvailabilityIcon: View {
    var style: FavoriteIndicatorStyle = .list
    @AppStorage("themeColor") private var themeColorName = "violet"

    var body: some View {
        Group {
            switch style {
            case .list:
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.color(for: themeColorName))
                    .frame(width: 14, height: 14)
            case .cover:
                Image(systemName: "heart.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.color(for: themeColorName))
                    .frame(width: 21, height: 21)
            }
        }
        .accessibilityLabel(String(localized: "favorite"))
    }
}

struct AlbumFavoriteBadge: View {
    let albumId: String
    var style: FavoriteIndicatorStyle = .list
    private let libraryStore = LibraryStore.shared
    @State private var isFavorite: Bool

    init(albumId: String, style: FavoriteIndicatorStyle = .list) {
        self.albumId = albumId
        self.style = style
        _isFavorite = State(
            initialValue: LibraryStore.shared.favoriteAlbums.contains { $0.id == albumId }
        )
    }

    var body: some View {
        Group {
            if isFavorite {
                switch style {
                case .list:
                    FavoriteAvailabilityIcon(style: .list)
                case .cover:
                    FavoriteAvailabilityIcon(style: .cover)
                        .coverStatusCapsule()
                }
            }
        }
        .onReceive(
            libraryStore.$favoriteAlbums
                .map { albums in albums.contains { $0.id == albumId } }
                .removeDuplicates()
        ) { isFavorite = $0 }
    }
}

struct ArtistFavoriteBadge: View {
    let artistId: String
    var style: FavoriteIndicatorStyle = .list
    private let libraryStore = LibraryStore.shared
    @State private var isFavorite: Bool

    init(artistId: String, style: FavoriteIndicatorStyle = .list) {
        self.artistId = artistId
        self.style = style
        _isFavorite = State(
            initialValue: LibraryStore.shared.favoriteArtists.contains { $0.id == artistId }
        )
    }

    var body: some View {
        Group {
            if isFavorite {
                switch style {
                case .list:
                    FavoriteAvailabilityIcon(style: .list)
                case .cover:
                    FavoriteAvailabilityIcon(style: .cover)
                        .coverStatusCapsule()
                }
            }
        }
        .onReceive(
            libraryStore.$favoriteArtists
                .map { artists in artists.contains { $0.id == artistId } }
                .removeDuplicates()
        ) { isFavorite = $0 }
    }
}

struct SongFavoriteBadge: View {
    let songId: String
    var style: FavoriteIndicatorStyle = .list
    private let libraryStore = LibraryStore.shared
    @State private var isFavorite: Bool

    init(songId: String, style: FavoriteIndicatorStyle = .list) {
        self.songId = songId
        self.style = style
        _isFavorite = State(
            initialValue: LibraryStore.shared.favoriteSongs.contains { $0.id == songId }
        )
    }

    var body: some View {
        Group {
            if isFavorite {
                switch style {
                case .list:
                    FavoriteAvailabilityIcon(style: .list)
                case .cover:
                    FavoriteAvailabilityIcon(style: .cover)
                        .coverStatusCapsule()
                }
            }
        }
        .onReceive(
            libraryStore.$favoriteSongs
                .map { songs in songs.contains { $0.id == songId } }
                .removeDuplicates()
        ) { isFavorite = $0 }
    }
}
