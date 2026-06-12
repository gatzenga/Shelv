import SwiftUI

/// Einheitliche Spalten für alle Cover-Grids: feste 240er-Cover (wie Discover),
/// linksbündig gepackt — nicht zentriert, nicht gestreckt. Auf 1920 pt → 6 Spalten.
let coverGridColumns = Array(repeating: GridItem(.fixed(240), spacing: 40), count: 6)

/// Album-Karte: das Cover hebt sich beim Fokus als Ganzes (nativer `.card`-Lift),
/// Titel/Künstler stehen mit genug Abstand darunter — keine umschließende Box.
struct AlbumCard: View {
    let album: Album
    var size: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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

/// Künstler-Karte: rundes Bild + Name. Das runde Bild zoomt als Ganzes beim Fokus
/// (deutlich, mit Schatten) — ein `.card`-Rechteck würde hier eine Box um den Kreis legen.
struct ArtistCard: View {
    let artist: Artist
    var size: CGFloat = 240

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            NavigationLink {
                ArtistDetailView(artist: artist)
            } label: {
                CoverArtView(url: artist.coverURL(500), size: size, isCircle: true)
                    .scaleEffect(focused ? 1.12 : 1.0)
                    .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 12)
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

/// Native Song-Zeile für `List` — in einer `List` liefert tvOS den Fokus-Highlight
/// automatisch. `showArtwork`: Cover-Thumbnail (Suche/Favoriten/Playlist) oder
/// Tracknummer (Albumansicht, wo alle Songs dasselbe Cover hätten).
struct SongRow: View {
    let song: Song
    let index: Int
    var showArtwork: Bool = true
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 20) {
                if showArtwork {
                    CoverArtView(url: song.coverURL(200), size: 64, cornerRadius: 6)
                } else {
                    Text("\(index + 1)")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
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
