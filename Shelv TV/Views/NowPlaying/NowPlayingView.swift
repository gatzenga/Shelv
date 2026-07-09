import SwiftUI

enum TVNowPlayingPanel: Equatable {
    case lyrics
    case queue
}

struct NowPlayingView: View {
    @Binding private var activeSidePanel: TVNowPlayingPanel?
    @Binding private var isRootVisible: Bool
    @ObservedObject var player = AudioPlayerService.shared
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var radioStore = RadioStationStore.shared
    @AppStorage("themeColor") private var themeColor = "violet"
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage("radioSortDirectionTV") private var radioSortDirectionRaw = SortDirection.ascending.rawValue
    @Environment(\.scenePhase) private var scenePhase
    private var accent: Color { AppTheme.color(for: themeColor) }
    private var radioDisplayItems: [RadioStationDisplayItem] {
        let direction = SortDirection(rawValue: radioSortDirectionRaw) ?? .ascending
        return direction == .descending ? Array(radioStore.items.reversed()) : radioStore.items
    }

    @State private var displayTime: Double = 0
    @State private var displayDuration: Double = 0
    @State private var panel: TVNowPlayingPanel?
    @State private var showSleepTimer = false

    private var sidePanelVisible: Bool {
        panel != nil && !player.isRadioPlayback
    }

    private var playerColumnOffsetX: CGFloat {
        sidePanelVisible ? -36 : 0
    }

    init(
        activeSidePanel: Binding<TVNowPlayingPanel?> = .constant(nil),
        isRootVisible: Binding<Bool> = .constant(false)
    ) {
        _activeSidePanel = activeSidePanel
        _isRootVisible = isRootVisible
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TVPlayerGradientBackground()

                Group {
                    if player.hasActivePlayback {
                        HStack(spacing: 0) {
                            playerColumn
                                .offset(x: playerColumnOffsetX)
                                .frame(maxWidth: .infinity)
                                .focusSection()

                            if let panel, !player.isRadioPlayback {
                                sidePanel(panel)
                                    .frame(width: 820)
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
            .onAppear {
                isRootVisible = true
                activeSidePanel = panel
            }
            .onDisappear {
                isRootVisible = false
                activeSidePanel = nil
            }
        }
        .onChange(of: panel) { _, panel in
            activeSidePanel = isRootVisible ? panel : nil
        }
    }

    // MARK: - Player (links)

    private var playerColumn: some View {
        VStack(spacing: 26) {
            if let station = player.currentRadioStation {
                TVRadioStationArtworkView(item: station, size: panel == nil ? 380 : 300, metadata: player.currentRadioMetadata)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                    .animation(.easeInOut(duration: 0.25), value: panel)
            } else {
                CoverArtView(url: player.currentSong?.coverURL(700), size: panel == nil ? 380 : 300, cornerRadius: 16)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                    .animation(.easeInOut(duration: 0.25), value: panel)
            }

            VStack(spacing: 6) {
                Text(player.displayTitle).font(.title2).bold().lineLimit(1)
                trackLinks
            }

            // Seek (tvOS hat keinen Slider: fokussierbare Bar, links/rechts springt in Schritten)
            VStack(spacing: 6) {
                if player.isRadioPlayback {
                    let statusColor: Color = player.isRadioConnecting
                        ? .orange
                        : (player.isPlaying ? .green : .secondary)

                    HStack(spacing: 10) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 9, height: 9)
                        Text(player.radioStatusText)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 620, minHeight: 34)
                } else {
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
            if player.isRadioPlayback {
                HStack(spacing: 30) {
                    Button { player.playPreviousRadioStation(in: radioDisplayItems) } label: {
                        Image(systemName: "backward.fill")
                    }
                    .disabled(radioDisplayItems.count <= 1)

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.body)
                    }

                    Button { player.playNextRadioStation(in: radioDisplayItems) } label: {
                        Image(systemName: "forward.fill")
                    }
                    .disabled(radioDisplayItems.count <= 1)
                }
                .font(.callout)
            } else {
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
            }

            // Sekundär: Radio zeigt nur Sleep Timer und Stop; Songs behalten Favorit, Lyrics und Queue.
            HStack(spacing: 30) {
                if player.isRadioPlayback {
                    Button { showSleepTimer = true } label: {
                        sleepTimerControlLabel
                    }
                    Button { player.stop() } label: { Image(systemName: "stop.fill") }
                } else {
                    if showFavoriteActions, let song = player.currentSong {
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
            }
            .font(.callout)
        }
        .padding(50)
        .confirmationDialog(
            String(localized: "sleep_timer"),
            isPresented: $showSleepTimer,
            titleVisibility: .visible
        ) {
            if player.sleepTimerEnd != nil {
                Button(String(localized: "cancel_timer"), role: .destructive) {
                    player.cancelSleepTimer()
                }
            }

            ForEach(Self.sleepTimerOptions, id: \.self) { minutes in
                Button(sleepTimerRowLabel(minutes: minutes)) {
                    player.setSleepTimer(minutes: minutes)
                }
            }
        }
    }

    @ViewBuilder
    private var sleepTimerControlLabel: some View {
        if let end = player.sleepTimerEnd {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(0, Int(end.timeIntervalSinceNow))
                Text(formatSleepTimer(remaining))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            }
        } else {
            Label(String(localized: "sleep_timer"), systemImage: "moon.zzz.fill")
        }
    }

    /// Künstler- und Album-Name als Navigationsziele.
    @ViewBuilder
    private var trackLinks: some View {
        if let song = player.currentSong {
            if let artist = song.artist {
                let libraryArtist = resolvedLibraryArtist(name: artist, id: song.artistId)
                AccentTextLink(text: artist, font: .body, color: Color.primary.opacity(0.78)) {
                    ArtistDetailView(artist: libraryArtist)
                }
                .artistContextMenu(libraryArtist)
            }
            if let album = song.album {
                if let alid = song.albumId, !alid.isEmpty {
                    let libraryAlbum = Album(id: alid, name: album, artist: song.artist,
                                             artistId: song.artistId, coverArt: song.coverArt)
                    AccentTextLink(text: album, font: .callout, color: Color.primary.opacity(0.60)) {
                        AlbumDetailView(album: libraryAlbum)
                    }
                    .albumContextMenu(libraryAlbum)
                } else {
                    Text(album)
                        .font(.callout)
                        .foregroundStyle(Color.primary.opacity(0.60))
                        .lineLimit(1)
                }
            }
        } else if player.isRadioPlayback {
            VStack(spacing: 4) {
                Text(player.radioDisplayArtistLine)
                    .font(.callout)
                    .foregroundStyle(Color.primary.opacity(0.60))
                    .lineLimit(1)
                    .accessibilityHidden(player.radioDisplayArtist.isEmpty)
                Text(player.radioDisplayStationName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .lineLimit(1)
            }
        }
    }

    /// Codec · Bitrate des tatsächlich laufenden Streams — identisch zu iOS/macOS.
    private var audioBadge: String? {
        player.actualStreamFormat?.displayString
    }

    private func toggle(_ p: TVNowPlayingPanel) {
        panel = (panel == p) ? nil : p
    }

    /// Anzeige-Zeit direkt aus dem (im Speicher gehaltenen) Player übernehmen — nötig wenn
    /// pausiert: dann feuert der timePublisher nicht und die Anzeige bliebe sonst bei 0.
    private func syncDisplayFromPlayer() {
        displayTime = player.currentTime
        displayDuration = player.duration
    }

    private static let sleepTimerOptions = [15, 30, 45, 60, 90, 120]

    private func sleepTimerRowLabel(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) \(String(localized: "minutes_abbreviation"))"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 {
            return "\(hours) \(String(localized: "hour_abbreviation"))"
        }
        return "\(hours) \(String(localized: "hour_abbreviation")) \(remainder) \(String(localized: "minutes_abbreviation"))"
    }

    private func formatSleepTimer(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    // MARK: - Seitenpanel (rechts)

    @ViewBuilder
    private func sidePanel(_ p: TVNowPlayingPanel) -> some View {
        switch p {
        case .lyrics:
            // Kein Kopf — Titel/Künstler stehen links in der Now-Playing-Spalte.
            LyricsView(horizontalPadding: 36)
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
