import SwiftUI

/// Dezenter, einheitlicher Fokus-Zoom für alle Cover-Karten — bewusst klein (1.05),
/// damit der gehobene Inhalt den darunterliegenden Titel nicht überdeckt.
private let coverFocusScale: CGFloat = 1.05

/// Album-Karte: nur das Cover ist fokussierbar, Titel/Künstler stehen darunter —
/// keine umschließende Box.
struct AlbumCard: View {
    let album: Album
    var size: CGFloat = 270

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                AlbumDetailView(album: album)
            } label: {
                CoverArtView(url: album.coverURL(500), size: size, cornerRadius: 8)
                    .scaleEffect(focused ? coverFocusScale : 1.0)
                    .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 10)
                    .animation(.easeOut(duration: 0.18), value: focused)
            }
            .buttonStyle(.borderless)
            .focused($focused)

            Text(album.name).lineLimit(1).font(.callout)
            if let artist = album.artist {
                Text(artist).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size)
    }
}

/// Künstler-Karte: rundes Bild + Name, keine Box. Gleicher dezenter Fokus-Zoom.
struct ArtistCard: View {
    let artist: Artist
    var size: CGFloat = 270

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            NavigationLink {
                ArtistDetailView(artist: artist)
            } label: {
                CoverArtView(url: artist.coverURL(500), size: size, isCircle: true)
                    .scaleEffect(focused ? coverFocusScale : 1.0)
                    .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 10)
                    .animation(.easeOut(duration: 0.18), value: focused)
            }
            .buttonStyle(.borderless)
            .focused($focused)

            Text(artist.name).lineLimit(1).font(.callout)
                .foregroundStyle(focused ? .primary : .secondary)
        }
        .frame(width: size)
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
