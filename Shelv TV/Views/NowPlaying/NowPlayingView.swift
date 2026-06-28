import SwiftUI

private enum SidePanel { case lyrics, queue }

struct NowPlayingView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @ObservedObject private var library = LibraryStore.shared
    @AppStorage("themeColor") private var themeColor = "violet"
    @AppStorage("enableFavorites") private var enableFavorites = true
    @Environment(\.scenePhase) private var scenePhase
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
                            .focusSection()

                        if let panel {
                            Divider()
                            sidePanel(panel)
                                .frame(width: 720)
                                .focusSection()
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: panel)
                    .onAppear { syncDisplayFromPlayer() }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { syncDisplayFromPlayer() }
                    }
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

                // Codec · Bitrate (gleiche Quelle/Logik wie iOS & macOS); bei Buffering „Loading".
                HStack(spacing: 6) {
                    if player.showBufferingIndicator {
                        ProgressView().scaleEffect(0.7).tint(.secondary)
                    }
                    Text(player.showBufferingIndicator ? String(localized: "loading_2") : (audioBadge ?? ""))
                }
                .font(.caption).foregroundStyle(.tertiary)
                .frame(height: 22)
            }

            // Transport
            HStack(spacing: 30) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.isShuffled ? accent : Color.primary)
                }
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    // Kein Spinner mehr — der Ladezustand steht bereits als „Loading" beim Codec-Badge.
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.body)
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

    /// Künstler- und Album-Name als Navigationsziele.
    @ViewBuilder
    private var trackLinks: some View {
        if let song = player.currentSong {
            if let artist = song.artist {
                let libraryArtist = resolvedLibraryArtist(name: artist, id: song.artistId)
                AccentTextLink(text: artist, font: .body) {
                    ArtistDetailView(artist: libraryArtist)
                }
                .artistContextMenu(libraryArtist)
            }
            if let album = song.album {
                if let alid = song.albumId, !alid.isEmpty {
                    let libraryAlbum = Album(id: alid, name: album, artist: song.artist,
                                             artistId: song.artistId, coverArt: song.coverArt)
                    AccentTextLink(text: album, font: .callout) {
                        AlbumDetailView(album: libraryAlbum)
                    }
                    .albumContextMenu(libraryAlbum)
                } else {
                    Text(album).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    /// Codec · Bitrate des tatsächlich laufenden Streams — identisch zu iOS/macOS.
    private var audioBadge: String? {
        player.actualStreamFormat?.displayString
    }

    private func toggle(_ p: SidePanel) {
        panel = (panel == p) ? nil : p
    }

    /// Anzeige-Zeit direkt aus dem (im Speicher gehaltenen) Player übernehmen — nötig wenn
    /// pausiert: dann feuert der timePublisher nicht und die Anzeige bliebe sonst bei 0.
    private func syncDisplayFromPlayer() {
        displayTime = player.currentTime
        displayDuration = player.duration
    }

    // MARK: - Seitenpanel (rechts)

    @ViewBuilder
    private func sidePanel(_ p: SidePanel) -> some View {
        switch p {
        case .lyrics:
            // Kein Kopf — Titel/Künstler stehen links in der Now-Playing-Spalte.
            LyricsView()
        case .queue:
            // Kein Kopf — die Sektionen (Als Nächstes / Nächste Titel / Deine Warteschlange) sind selbsterklärend.
            QueueView()
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
        // Fokus wird über die Farbe gezeigt (Akzent statt Weiß) — nicht über Vergrößerung,
        // die sonst den Text darunter überdecken würde. Sprung in sauberen 15-Sekunden-Schritten.
        ProgressView(value: duration > 0 ? min(time / duration, 1) : 0)
            .tint(focused ? accent : .white)
            .frame(maxWidth: 620)
            .focusable()
            .focused($focused)
            .onMoveCommand { direction in
                switch direction {
                case .left:  onSeek(max(0, time - 15))
                case .right: onSeek(min(duration, time + 15))
                default: break
                }
            }
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
