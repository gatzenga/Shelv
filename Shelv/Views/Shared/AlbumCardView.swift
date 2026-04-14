import SwiftUI

struct AlbumCardView: View {
    let album: Album
    var fixedSize: CGFloat? = nil
    var showArtist: Bool = true
    var showYear: Bool = false

    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = fixedSize {
                AlbumArtView(coverArtId: album.coverArt, size: 300, cornerRadius: 12)
                    .frame(width: s, height: s)
            } else {
                AlbumArtView(coverArtId: album.coverArt, size: 300, cornerRadius: 12)
                    .aspectRatio(1, contentMode: .fit)
            }
            Text(album.name)
                .font(.caption).bold()
                .lineLimit(2)
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
        .contextMenu {
            Button {
                Task {
                    guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                          let songs = detail.song, !songs.isEmpty else { return }
                    await MainActor.run { AudioPlayerService.shared.play(songs: songs, startIndex: 0) }
                }
            } label: {
                Label(tr("Play", "Abspielen"), systemImage: "play.fill")
            }

            Button {
                Task {
                    guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                          let songs = detail.song, !songs.isEmpty else { return }
                    await MainActor.run { AudioPlayerService.shared.play(songs: songs.shuffled(), startIndex: 0) }
                }
            } label: {
                Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
            }

            Divider()

            Button {
                Task {
                    guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                          let songs = detail.song, !songs.isEmpty else { return }
                    await MainActor.run { AudioPlayerService.shared.addPlayNext(songs) }
                }
            } label: {
                Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
            }

            Button {
                Task {
                    guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                          let songs = detail.song, !songs.isEmpty else { return }
                    await MainActor.run { AudioPlayerService.shared.addToQueue(songs) }
                }
            } label: {
                Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
            }
        } preview: {
            AlbumArtView(coverArtId: album.coverArt, size: 600, cornerRadius: 0)
                .frame(width: 280, height: 280)
        }
    }
}
