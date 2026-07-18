import Combine
import SwiftUI

struct DownloadedArtistAvailability: Equatable {
    let isCatalogDownloaded: Bool
    let isBadgeDownloaded: Bool

    fileprivate init(isCatalogDownloaded: Bool, isBadgeDownloaded: Bool) {
        self.isCatalogDownloaded = isCatalogDownloaded
        self.isBadgeDownloaded = isBadgeDownloaded
    }
}

struct AlbumDownloadStatusReader<Content: View>: View {
    let albumID: String
    let totalSongs: Int
    private let content: (AlbumDownloadStatus) -> Content

    @State private var downloadedCount: Int

    init(
        albumID: String,
        totalSongs: Int,
        @ViewBuilder content: @escaping (AlbumDownloadStatus) -> Content
    ) {
        self.albumID = albumID
        self.totalSongs = totalSongs
        self.content = content
        _downloadedCount = State(
            initialValue: DownloadUIStateHub.shared.albumDownloadedCount(albumID)
        )
    }

    var body: some View {
        content(downloadStatus)
            .onReceive(
                DownloadUIStateHub.shared.albumDownloadedCountPublisher(albumID: albumID)
            ) { downloadedCount = $0 }
    }

    private var downloadStatus: AlbumDownloadStatus {
        if downloadedCount == 0 { return .none }
        if downloadedCount >= totalSongs { return .complete }
        return .partial(downloaded: downloadedCount, total: totalSongs)
    }
}

struct ArtistDownloadAvailabilityReader<Content: View>: View {
    let artistName: String
    private let content: (DownloadedArtistAvailability) -> Content

    @State private var availability: DownloadedArtistAvailability

    init(
        artistName: String,
        @ViewBuilder content: @escaping (DownloadedArtistAvailability) -> Content
    ) {
        self.artistName = artistName
        self.content = content
        _availability = State(
            initialValue: DownloadedArtistAvailability(
                isCatalogDownloaded: DownloadUIStateHub.shared
                    .isCatalogArtistDownloaded(artistName),
                isBadgeDownloaded: DownloadUIStateHub.shared
                    .isArtistBadgeDownloaded(artistName)
            )
        )
    }

    var body: some View {
        content(availability)
            .onReceive(
                Publishers.CombineLatest(
                    DownloadUIStateHub.shared
                        .catalogArtistAvailabilityPublisher(name: artistName),
                    DownloadUIStateHub.shared
                        .artistAvailabilityPublisher(name: artistName)
                )
                    .map { values in
                        DownloadedArtistAvailability(
                            isCatalogDownloaded: values.0,
                            isBadgeDownloaded: values.1
                        )
                    }
                    .removeDuplicates()
            ) { availability = $0 }
    }
}

struct LibraryAlbumListRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: album.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let artist = album.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let year = album.year {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            AlbumDownloadBadge(albumId: album.id)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct LibraryArtistGridCell: View {
    let artist: Artist
    let isDownloaded: Bool
    let accentColor: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AlbumArtView(coverArtId: artist.coverArt, size: 300, isCircle: true)
                    .aspectRatio(1, contentMode: .fit)
                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(accentColor, in: Circle())
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(6)
                }
            }
            Text(artist.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }
}

struct LibraryArtistListRow: View {
    let artist: Artist
    let localAlbumCount: Int
    let isDownloaded: Bool
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: artist.coverArt, size: 150, isCircle: true)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if localAlbumCount > 0 {
                    Text("\(localAlbumCount) \(String(localized: "albums"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(accentColor, in: Circle())
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

struct LibraryFavoriteArtistRow: View {
    let artist: Artist
    let isDownloaded: Bool
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: artist.coverArt, size: 150, isCircle: true)
                .frame(width: 44, height: 44)
            Text(artist.name)
                .font(.body)
                .lineLimit(1)
            Spacer()
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct LibraryFavoriteAlbumRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: album.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.body)
                    .lineLimit(1)
                if let artist = album.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            AlbumDownloadBadge(albumId: album.id)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct LibraryStarredSongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: song.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let artist = song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            DownloadStatusIcon(songId: song.id)
            Text(song.durationFormatted)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct LibraryLetterHeader: View {
    let letter: String
    let id: String

    var body: some View {
        Text(letter)
            .font(.title2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: Color(UIColor.systemBackground),              location: 0.0),
                        .init(color: Color(UIColor.systemBackground),              location: 0.65),
                        .init(color: Color(UIColor.systemBackground).opacity(0),   location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .id(id)
    }
}
