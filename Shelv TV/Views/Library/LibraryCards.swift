import SwiftUI

/// Fokussierbare Album-Karte (Cover + Titel + Künstler). `.card`-Style gibt den nativen
/// tvOS-Fokus-Lift.
struct AlbumCard: View {
    let album: Album
    var size: CGFloat = 260

    var body: some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CoverArtView(url: album.coverURL(500), size: size, cornerRadius: 8)
                Text(album.name).lineLimit(1).font(.callout)
                if let artist = album.artist {
                    Text(artist).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: size)
        }
        .buttonStyle(.card)
    }
}

/// Fokussierbare Künstler-Karte (rundes Cover).
struct ArtistCard: View {
    let artist: Artist
    var size: CGFloat = 260

    var body: some View {
        NavigationLink {
            ArtistDetailView(artist: artist)
        } label: {
            VStack(spacing: 8) {
                CoverArtView(url: artist.coverURL(500), size: size, isCircle: true)
                Text(artist.name).lineLimit(1).font(.callout)
            }
            .frame(width: size)
        }
        .buttonStyle(.card)
    }
}

/// Native Song-Zeile für `List` — Cover-Thumbnail + Titel/Künstler + Dauer.
/// In einer `List` liefert tvOS den Fokus-Highlight automatisch.
struct SongRow: View {
    let song: Song
    let index: Int
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 20) {
                CoverArtView(url: song.coverURL(200), size: 72, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).lineLimit(1)
                    if let artist = song.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let d = song.duration {
                    Text(formatDuration(d)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

func formatDuration(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}
