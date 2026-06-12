import SwiftUI

/// Album-Karte: nur das Cover ist fokussierbar (`.card`-Lift), Titel/Künstler stehen
/// darunter — keine umschließende Box.
struct AlbumCard: View {
    let album: Album
    var size: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                AlbumDetailView(album: album)
            } label: {
                CoverArtView(url: album.coverURL(500), size: size, cornerRadius: 8)
            }
            .buttonStyle(.card)

            Text(album.name).lineLimit(1).font(.callout)
            if let artist = album.artist {
                Text(artist).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size)
    }
}

/// Künstler-Karte: rundes Bild + Name, keine Box. Eigener Fokus-Lift (Skalierung +
/// Schatten). Der Button-Frame reserviert den Lift-Raum, damit das Bild weder den
/// Text überdeckt noch am Rand abgeschnitten wird.
struct ArtistCard: View {
    let artist: Artist
    var size: CGFloat = 260

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            NavigationLink {
                ArtistDetailView(artist: artist)
            } label: {
                CoverArtView(url: artist.coverURL(500), size: size, isCircle: true)
                    .scaleEffect(focused ? 1.06 : 1.0)
                    .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 20, y: 10)
                    .animation(.easeOut(duration: 0.18), value: focused)
            }
            .buttonStyle(.borderless)
            .focused($focused)
            .frame(width: size * 1.1, height: size * 1.1)   // reservierter Lift-Raum

            Text(artist.name).lineLimit(1).font(.callout)
                .foregroundStyle(focused ? .primary : .secondary)
        }
        .frame(width: size * 1.1)
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
