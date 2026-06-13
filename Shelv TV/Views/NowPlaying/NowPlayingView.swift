import SwiftUI

private enum SidePanel { case lyrics, queue }

struct NowPlayingView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @ObservedObject private var library = LibraryStore.shared
    @AppStorage("themeColor") private var themeColor = "violet"
    @AppStorage("enableFavorites") private var enableFavorites = true
    private var accent: Color { AppTheme.color(for: themeColor) }

    @State private var displayTime: Double = 0
    @State private var displayDuration: Double = 0
    @State private var panel: SidePanel?

    var body: some View {
        NavigationStack {
            Group {
                if player.currentSong != nil {
                    HStack(spacing: 0) {
                        playerColumn
                            .frame(maxWidth: .infinity)

                        if let panel {
                            Divider()
                            sidePanel(panel)
                                .frame(width: 720)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: panel)
                    .onReceive(player.timePublisher) { t in
                        displayTime = t.time
                        displayDuration = t.duration
                    }
                } else {
                    ContentUnavailableView(
                        String(localized: "nothing_playing"),
                        systemImage: "play.slash"
                    )
                }
            }
        }
    }

    // MARK: - Player (links)

    private var playerColumn: some View {
        VStack(spacing: 26) {
            CoverArtView(url: player.currentSong?.coverURL(700), size: panel == nil ? 380 : 300, cornerRadius: 16)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                .animation(.easeInOut(duration: 0.25), value: panel)

            VStack(spacing: 6) {
                Text(player.displayTitle).font(.title2).bold().lineLimit(1)
                trackLinks
            }

            // Seek (tvOS hat keinen Slider: fokussierbare Bar, links/rechts springt in Schritten)
            VStack(spacing: 6) {
                SeekBar(time: displayTime, duration: displayDuration, accent: accent) { target in
                    displayTime = target
                    player.seek(to: target)
                }
                HStack {
                    Text(formatDuration(Int(displayTime))).monospacedDigit()
                    Spacer()
                    Text(formatDuration(Int(displayDuration))).monospacedDigit()
                }
                .frame(maxWidth: 620)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Transport
            HStack(spacing: 30) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.isShuffled ? accent : Color.primary)
                }
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    if player.showBufferingIndicator {
                        ProgressView().tint(accent)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.body)
                    }
                }
                Button { player.next(triggeredByUser: true) } label: { Image(systemName: "forward.fill") }
                Button { player.repeatMode = player.repeatMode.toggled } label: {
                    Image(systemName: player.repeatMode.systemImage)
                        .foregroundStyle(player.repeatMode == .off ? Color.primary : accent)
                }
            }
            .font(.callout)

            // Sekundär: Favorit · Lyrics · Queue · Stop
            HStack(spacing: 30) {
                if enableFavorites, let song = player.currentSong {
                    Button { Task { await library.toggleStarSong(song) } } label: {
                        Image(systemName: library.isSongStarred(song) ? "heart.fill" : "heart")
                            .foregroundStyle(library.isSongStarred(song) ? accent : Color.primary)
                    }
                }
                Button { toggle(.lyrics) } label: {
                    Label(String(localized: "lyrics"), systemImage: "text.quote")
                        .foregroundStyle(panel == .lyrics ? accent : Color.primary)
                }
                Button { toggle(.queue) } label: {
                    Label(String(localized: "queue"), systemImage: "list.bullet")
                        .foregroundStyle(panel == .queue ? accent : Color.primary)
                }
                Button { player.stop() } label: { Image(systemName: "stop.fill") }
            }
            .font(.callout)
        }
        .padding(50)
    }

    /// Künstler- und Album-Name als Navigationsziele (wenn IDs vorhanden).
    @ViewBuilder
    private var trackLinks: some View {
        if let song = player.currentSong {
            if let artist = song.artist {
                if let aid = song.artistId, !aid.isEmpty {
                    NavigationLink {
                        ArtistDetailView(artist: Artist(id: aid, name: artist))
                    } label: {
                        Text(artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let album = song.album {
                if let alid = song.albumId, !alid.isEmpty {
                    NavigationLink {
                        AlbumDetailView(album: Album(id: alid, name: album, artist: song.artist,
                                                     artistId: song.artistId, coverArt: song.coverArt))
                    } label: {
                        Text(album).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(album).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    private func toggle(_ p: SidePanel) {
        panel = (panel == p) ? nil : p
    }

    // MARK: - Seitenpanel (rechts)

    @ViewBuilder
    private func sidePanel(_ p: SidePanel) -> some View {
        switch p {
        case .lyrics:
            // Kein Kopf — Titel/Künstler stehen links in der Now-Playing-Spalte.
            LyricsView()
        case .queue:
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "queue"))
                    .font(.title2).bold()
                    .padding(.horizontal, 50)
                    .padding(.top, 50)
                    .padding(.bottom, 12)
                QueueView()
            }
        }
    }
}

/// tvOS-Seek-Bar: fokussierbar; links/rechts auf der Remote springt in 5%-Schritten (min. 10 s).
private struct SeekBar: View {
    let time: Double
    let duration: Double
    let accent: Color
    let onSeek: (Double) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ProgressView(value: duration > 0 ? min(time / duration, 1) : 0)
            .tint(accent)
            .frame(maxWidth: 620)
            .scaleEffect(y: focused ? 2.2 : 1.0)
            .focusable()
            .focused($focused)
            .onMoveCommand { direction in
                let step = max(duration / 20, 10)
                switch direction {
                case .left:  onSeek(max(0, time - step))
                case .right: onSeek(min(duration, time + step))
                default: break
                }
            }
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
