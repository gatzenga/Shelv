import SwiftUI

struct AlbumCardView: View {
    let album: Album
    var fixedSize: CGFloat? = nil
    var showArtist: Bool = true
    var showYear: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let s = fixedSize {
                    AlbumArtView(coverArtId: album.coverArt, size: 300, cornerRadius: 12)
                        .frame(width: s, height: s)
                } else {
                    AlbumArtView(coverArtId: album.coverArt, size: 300, cornerRadius: 12)
                        .aspectRatio(1, contentMode: .fit)
                }
                AlbumDownloadBadge(albumId: album.id)
                    .padding(6)
            }
            Text(album.name)
                .font(.caption).bold()
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
            if showArtist, let artist = album.artist {
                Text(artist)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            if showYear, let year = album.year {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: fixedSize)
        .albumContextMenu(album)
    }
}
