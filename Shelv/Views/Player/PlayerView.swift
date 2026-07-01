import SwiftUI
import AVKit

private final class PlayerPaletteResult: NSObject {
    let primary: UIColor
    let secondary: UIColor?
    init(_ primary: UIColor, _ secondary: UIColor?) {
        self.primary = primary
        self.secondary = secondary
    }
}

private struct NativePlayerProgressSlider: View {
    @Binding var value: Double
    let trackColor: Color
    let fillColor: Color
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)

                Capsule()
                    .fill(fillColor)
                    .frame(width: progressWidth(in: width))
                    .animation(nil, value: value)
            }
            .frame(height: isDragging ? 12 : 5)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isDragging)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard width > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let ratio = gesture.location.x / width
                        let clamped = min(1, max(0, ratio))
                        dragValue = clamped
                        value = clamped
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragValue = nil
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 32)
        .accessibilityLabel(String(localized: "playback_position"))
        .accessibilityValue("\(Int(value * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(value + 0.05, 1)
            case .decrement:
                value = max(value - 0.05, 0)
            @unknown default:
                break
            }
            onEditingChanged(false)
        }
    }

    private func progressWidth(in width: CGFloat) -> CGFloat {
        let displayedValue = dragValue ?? value
        return width * min(1, max(0, displayedValue))
    }
}

struct PlayerView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject private var radioStore = RadioStationStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage(PersonalizationPreferenceKey.miniPlayerStyle) private var interfaceStyleRaw = PersonalizationMiniPlayerStyle.shelv.rawValue

    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage("radioSortDirection") private var radioSortDirectionRaw = SortDirection.ascending.rawValue

    @State private var seekValue: Double = 0
    @State private var isDragging: Bool = false
    @State private var displayTime: Double = 0
    @State private var displayDuration: Double = 0
    @State private var showQueue: Bool = false
    @State private var showAddToPlaylist = false
    @State private var showLyricsSheet: Bool = false
    @State private var showSleepTimer = false
    @State private var artistDestination: Artist?
    @State private var isResolvingArtist = false
    @State private var artistResolveTask: Task<Void, Never>?
    @State private var rawPrimary: UIColor? = nil
    @State private var rawSecondary: UIColor? = nil
    @State private var playerBgPrimary: Color = Color(UIColor.systemBackground)
    @State private var playerBgSecondary: Color = Color(UIColor.systemBackground)

    private static let paletteCache: NSCache<NSString, PlayerPaletteResult> = {
        let c = NSCache<NSString, PlayerPaletteResult>()
        c.countLimit = 200
        return c
    }()

    private var currentAlbum: Album? {
        guard let song = player.currentSong, let albumId = song.albumId else { return nil }
        return Album(
            id: albumId, name: song.album ?? "", artist: song.artist, artistId: nil,
            coverArt: song.coverArt, songCount: nil, duration: nil, year: song.year,
            genre: song.genre, playCount: nil, starred: nil, created: nil, songs: nil
        )
    }

    private var currentArtist: Artist? {
        guard let name = player.currentSong?.artist else { return nil }
        return libraryStore.artists.first { $0.name == name }
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var usesNativeInterface: Bool {
        PersonalizationMiniPlayerStyle(rawValue: interfaceStyleRaw) == .native
    }
    private var progressFraction: Binding<Double> {
        Binding(
            get: { displayDuration > 0 ? displayTime / displayDuration : 0 },
            set: { seekValue = min(1, max(0, $0)) }
        )
    }
    private var activeProgressFraction: Binding<Double> {
        (isDragging || player.isSeeking) ? $seekValue : progressFraction
    }
    private var playerBackgroundIdentifier: String {
        if player.isRadioPlayback {
            guard let station = player.currentRadioStation else { return "radio-none" }
            if station.usesDynamicSongCover,
               let metadata = player.currentRadioMetadata,
               trimmedNonEmpty(metadata.artworkURL) != nil {
                return "radio-art-\(metadata.artworkRevisionToken)"
            }
            if let coverArt = trimmedNonEmpty(station.coverArt) {
                return "radio-cover-\(coverArt)"
            }
            return "radio-station-\(station.id)"
        }
        return player.currentSong?.coverArt ?? "song-none"
    }

    private var radioDisplayItems: [RadioStationDisplayItem] {
        let direction = SortDirection(rawValue: radioSortDirectionRaw) ?? .ascending
        return direction == .descending ? Array(radioStore.items.reversed()) : radioStore.items
    }

    // Track-Infos (Titel/Artist/Album) als eigene View — entlastet den Type-Checker
    // des großen body und hält die Marquee-Logik beisammen. Auf Slider-Breite begrenzt.
    @ViewBuilder
    private var trackInfo: some View {
        VStack(spacing: isPad ? 6 : 8) {
            MarqueeText(text: player.displayTitle,
                        uiFont: .preferred(isPad ? .title1 : .title2, bold: true))

            if let artistName = player.currentSong?.artist {
                Button { resolveArtist(artistName) } label: {
                    MarqueeText(text: artistName,
                                uiFont: .preferred(isPad ? .title2 : .title3),
                                color: Color(.secondaryLabel))
                }
                .buttonStyle(.plain)
                .navigationDestination(item: $artistDestination) { artist in
                    ArtistDetailView(artist: artist)
                        .toolbarBackground(.visible, for: .navigationBar)
                }
            }

            if let album = currentAlbum {
                NavigationLink(destination: AlbumDetailView(album: album)
                    .toolbarBackground(.visible, for: .navigationBar)
                ) {
                    MarqueeText(text: album.name,
                                uiFont: .preferred(.callout),
                                color: Color(.tertiaryLabel))
                }
                .buttonStyle(.plain)
            } else if let albumName = player.currentSong?.album {
                MarqueeText(text: albumName,
                            uiFont: .preferred(.callout),
                            color: Color(.tertiaryLabel))
            } else if player.isRadioPlayback {
                MarqueeText(text: player.displaySubtitleLine,
                            uiFont: .preferred(.callout),
                            color: Color(.tertiaryLabel))
            }
        }
        .padding(.horizontal, isPad ? 48 : 32)
    }

    private func artSize(_ h: CGFloat) -> CGFloat {
        isPad ? min(480, max(300, h * 0.50)) : min(280, h * 0.44)
    }
    private func radioPlayButtonSize(_ h: CGFloat) -> CGFloat { isPad ? min(96, max(72, h * 0.11)) : 75 }
    private func radioControlSize(_ h: CGFloat) -> CGFloat { isPad ? min(56, max(44, h * 0.065)) : 50 }
    private func visibleArtSize(_ h: CGFloat) -> CGFloat {
        let base = artSize(h)
        let extra: CGFloat = isPad ? min(56, max(36, h * 0.045)) : (h < 700 ? 18 : 30)
        return min(isPad ? 536 : 310, base + extra)
    }
    private func playButtonSize(_ h: CGFloat) -> CGFloat { isPad ? min(96, max(72, h * 0.11)) : 72 }
    private func controlSize(_ h: CGFloat) -> CGFloat { isPad ? min(56, max(44, h * 0.065)) : 44 }
    private func vPad(_ h: CGFloat, large: CGFloat, small: CGFloat) -> CGFloat {
        if isPad { return h < 760 ? max(small * 0.6, large * 0.5) : large }
        // iPhone SE und ähnlich kleine Displays (h < 680 pt): Abstände halbieren
        return h < 680 ? max(small * 0.5, 4) : small
    }

    @ViewBuilder
    private var playbackProgressControl: some View {
        if usesNativeInterface {
            NativePlayerProgressSlider(
                value: activeProgressFraction,
                trackColor: Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.14),
                fillColor: Color.primary.opacity(0.88),
                onEditingChanged: handleSeekEditing
            )
        } else {
            Slider(
                value: activeProgressFraction,
                in: 0...1
            ) { editing in
                handleSeekEditing(editing)
            }
            .tint(accentColor)
        }
    }

    private func handleSeekEditing(_ editing: Bool) {
        if editing {
            isDragging = true
            seekValue = displayDuration > 0 ? displayTime / displayDuration : 0
        } else {
            let seconds = seekValue * displayDuration
            displayTime = seconds
            player.seek(to: seconds)
            isDragging = false
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Hintergrund-Verlauf als Root-Layer, damit er bis ganz nach oben hinter die
                // Navigation Bar (Schließen-Pfeil/AirPlay) reicht. Lag er als .background am
                // GeometryReader-frame, blieb der obere Safe-Area-Streifen schwarz.
                LinearGradient(
                    stops: [
                        .init(color: playerBgPrimary, location: 0.0),
                        .init(color: playerBgPrimary, location: 0.45),
                        .init(color: playerBgSecondary, location: 0.75),
                        .init(color: playerBgSecondary, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                GeometryReader { geo in
                let h = geo.size.height
                let art = artSize(h)
                let visibleArt = visibleArtSize(h)
                let play = playButtonSize(h)
                let ctrl = controlSize(h)
                let radioArt = visibleArt
                let radioPlay = radioPlayButtonSize(h)
                let radioCtrl = radioControlSize(h)
                Group {
                    if player.isRadioPlayback {
                        radioPlayerContent(
                            artworkFrameSize: art,
                            artworkSize: radioArt,
                            playSize: radioPlay,
                            controlSize: radioCtrl,
                            height: h
                        )
                    } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    ZStack(alignment: .bottom) {
                        if let station = player.currentRadioStation {
                            RadioStationArtworkView(item: station, size: visibleArt, metadata: player.currentRadioMetadata)
                        } else {
                            AlbumArtView(coverArtId: player.currentSong?.coverArt, size: 600, cornerRadius: isPad ? 22 : 20)
                                .frame(width: visibleArt, height: visibleArt)
                        }
                    }
                    .frame(width: art, height: art, alignment: .bottom)
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
                    .padding(.bottom, vPad(h, large: 20, small: 28))

                    trackInfo

                    Spacer(minLength: 0)

                    VStack(spacing: 4) {
                        if player.isRadioPlayback {
                            let statusColor: Color = player.isRadioConnecting
                                ? .orange
                                : (player.isPlaying ? .green : .secondary)

                            HStack(spacing: 8) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 7, height: 7)
                                Text(player.radioStatusText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: 32)
                        } else {
                            playbackProgressControl

                            HStack {
                                Text(formatTime(isDragging ? seekValue * displayDuration : displayTime))
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                Spacer()
                                Text(formatTime(displayDuration))
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }

                        HStack(spacing: 4) {
                            if player.showBufferingIndicator {
                                ProgressView()
                                    .scaleEffect(0.65)
                                    .tint(.secondary)
                                    .frame(width: 12, height: 12)
                            }
                            Text(player.showBufferingIndicator ? String(localized: "loading_2") : (audioBadge ?? ""))
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(height: 14)
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, isPad ? 48 : 32)
                    .padding(.bottom, vPad(h, large: 24, small: 32))

                    // Transport-Buttons
                    Group {
                        if player.isRadioPlayback {
                            Button { player.togglePlayPause() } label: {
                                ZStack {
                                    Circle().fill(accentColor).frame(width: play, height: play)
                                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: isPad ? 34 : 30)).foregroundStyle(.white)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            HStack(spacing: isPad ? 28 : 22) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: isPad ? 22 : 19, weight: .semibold))
                                    .foregroundStyle(player.isShuffled ? accentColor : .secondary)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                                    .onTapGesture { player.toggleShuffle() }

                                Image(systemName: "backward.fill")
                                    .font(.system(size: isPad ? 28 : 24))
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                                    .onTapGesture { player.previous() }

                                Button { player.togglePlayPause() } label: {
                                    ZStack {
                                        Circle().fill(accentColor).frame(width: play, height: play)
                                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: isPad ? 34 : 30)).foregroundStyle(.white)
                                    }
                                }
                                .buttonStyle(.plain)

                                Image(systemName: "forward.fill")
                                    .font(.system(size: isPad ? 28 : 24))
                                    .foregroundStyle(player.hasNextTrack ? Color.primary : Color.secondary)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                                    .onTapGesture { player.next(triggeredByUser: true) }
                                    .disabled(!player.hasNextTrack)

                                Image(systemName: player.repeatMode.systemImage)
                                    .font(.system(size: isPad ? 22 : 19, weight: .semibold))
                                    .foregroundStyle(player.repeatMode != .off ? accentColor : .secondary)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                                    .onTapGesture { player.cycleRepeatMode() }
                            }
                        }
                    }
                    .padding(.bottom, vPad(h, large: 36, small: 20))

                    // Sekundäre Buttons — Amperfy-Stil: grauer Kreis, .primary Icon
                    HStack {
                        if !player.isRadioPlayback, showFavoriteActions && !offlineMode.isOffline, let song = player.currentSong {
                            Button {
                                Task { await libraryStore.toggleStarSong(song) }
                            } label: {
                                playerSecondaryButton(
                                    icon: libraryStore.isSongStarred(song) ? "heart.fill" : "heart",
                                    color: libraryStore.isSongStarred(song) ? Color.pink : Color.primary,
                                    size: ctrl, isPad: isPad
                                )
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }

                        if !player.isRadioPlayback {
                            Button { showLyricsSheet = true } label: {
                                playerSecondaryButton(icon: "quote.bubble", color: .primary, size: ctrl, isPad: isPad)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button { showQueue = true } label: {
                                playerSecondaryButton(icon: "list.bullet", color: .primary, size: ctrl, isPad: isPad)
                            }
                            .buttonStyle(.plain)

                            if showPlaylistActions && !offlineMode.isOffline {
                                Spacer()
                                Button { showAddToPlaylist = true } label: {
                                    playerSecondaryButton(icon: "music.note.list", color: .primary, size: ctrl, isPad: isPad)
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer()
                        }

                        if player.isRadioPlayback {
                            Button { showSleepTimer = true } label: {
                                sleepTimerButton(size: ctrl, isPad: isPad)
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }

                        Button { player.stop(); dismiss() } label: {
                            playerSecondaryButton(icon: "stop.fill", color: .primary, size: ctrl, isPad: isPad)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, isPad ? 44 : 36)
                    .padding(.bottom, vPad(h, large: 32, small: 40))
                }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        AirPlayButton(tintColor: .label, activeTintColor: UIColor(accentColor))
                            .frame(width: 34, height: 34)
                    }
                }
                .navigationDestination(isPresented: $showLyricsSheet) {
                    LyricsSheetView()
                        .toolbarBackground(.visible, for: .navigationBar)
                }
                .onChange(of: player.currentSong?.id) { _, _ in
                    artistResolveTask?.cancel()
                    artistResolveTask = nil
                    isResolvingArtist = false
                }
                .task(id: playerBackgroundIdentifier) {
                    await updatePlayerBackground()
                }
                .onChange(of: colorScheme) { _, _ in
                    guard let raw = rawPrimary else { return }
                    playerBgPrimary = adaptedColor(raw, asSecondary: false)
                    playerBgSecondary = adaptedColor(rawSecondary ?? raw, asSecondary: true)
                }
                .onReceive(player.timePublisher) { update in
                    guard !isDragging, !player.isSeeking else { return }
                    displayTime = update.time
                    displayDuration = update.duration
                }
                .onAppear { displayTime = player.currentTime; displayDuration = player.duration }
                .onDisappear { artistResolveTask?.cancel(); artistResolveTask = nil }
                .sheet(isPresented: $showQueue) {
                    QueueView()
                        .presentationSizing(.page)
                        .presentationCornerRadius(24)
                        .presentationDragIndicator(.visible)
                        .tint(accentColor)
                }
                .sheet(isPresented: $showAddToPlaylist) {
                    if let song = player.currentSong {
                        AddToPlaylistSheet(songIds: [song.id])
                            .environmentObject(libraryStore)
                            .tint(accentColor)
                    }
                }
                .sheet(isPresented: $showSleepTimer) {
                    SleepTimerPanel()
                        .presentationSizing(.page)
                        .presentationCornerRadius(24)
                        .presentationDragIndicator(.visible)
                        .tint(accentColor)
                }
            }
            }
        }
    }

    @ViewBuilder
    private func radioPlayerContent(
        artworkFrameSize artFrame: CGFloat,
        artworkSize art: CGFloat,
        playSize play: CGFloat,
        controlSize ctrl: CGFloat,
        height h: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            radioFullscreenArtwork(size: art)
                .frame(width: artFrame, height: artFrame, alignment: .bottom)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
                .padding(.bottom, vPad(h, large: 20, small: 20))

            VStack(spacing: isPad ? 6 : 10) {
                Text(radioStationName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                radioStatusPill

                Text(radioTrackTitle)
                    .font(.title2)
                    .bold()
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 20)

                Text(radioTrackArtistLine)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.horizontal, 20)
                    .accessibilityHidden(radioTrackArtist.isEmpty)
            }

            Spacer(minLength: 0)

            HStack(spacing: isPad ? 28 : 22) {
                radioSkipButton(systemImage: "backward.fill", size: ctrl) {
                    player.playPreviousRadioStation(in: radioDisplayItems)
                }

                Button {
                    player.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(accentColor)
                            .frame(width: play, height: play)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: isPad ? 34 : 30))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)

                radioSkipButton(systemImage: "forward.fill", size: ctrl) {
                    player.playNextRadioStation(in: radioDisplayItems)
                }
            }
            .padding(.bottom, vPad(h, large: 36, small: 32))

            HStack(spacing: isPad ? 80 : 60) {
                Button { showSleepTimer = true } label: {
                    sleepTimerButton(size: ctrl, isPad: isPad)
                }
                .buttonStyle(.plain)

                Button {
                    player.stop()
                    dismiss()
                } label: {
                    playerSecondaryButton(icon: "stop.fill", color: .primary, size: ctrl, isPad: isPad)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, vPad(h, large: 32, small: 50))
        }
    }

    private func radioSkipButton(systemImage: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isPad ? 28 : 24))
                .foregroundStyle(radioDisplayItems.count > 1 ? Color.primary : Color.secondary)
                .frame(width: max(44, size), height: max(44, size))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(radioDisplayItems.count <= 1)
    }

    @ViewBuilder
    private func radioFullscreenArtwork(size: CGFloat) -> some View {
        ZStack {
            if let url = radioRemoteArtworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        radioStationFallbackArtwork(size: size)
                    }
                }
            } else {
                radioStationFallbackArtwork(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: isPad ? 22 : 24, style: .continuous))
    }

    @ViewBuilder
    private func radioStationFallbackArtwork(size: CGFloat) -> some View {
        if let coverArt = player.currentRadioStation?.coverArt {
            RadioStationPlayerArtworkView(
                coverArtId: coverArt,
                displaySize: size,
                cornerRadius: isPad ? 22 : 24
            )
        } else {
            radioPlaceholderArtwork
        }
    }

    private var radioRemoteArtworkURL: URL? {
        guard player.currentRadioStation?.usesDynamicSongCover == true else { return nil }
        return player.currentRadioMetadata?.cacheBustedArtworkURL
    }

    private var radioStationName: String {
        player.radioDisplayStationName
    }

    private var radioTrackTitle: String {
        player.radioDisplayTitle
    }

    private var radioTrackArtist: String {
        player.radioDisplayArtist
    }

    private var radioTrackArtistLine: String {
        player.radioDisplayArtistLine
    }

    private var radioStatusConfiguration: (title: String, systemImage: String, color: Color) {
        if player.isRadioConnecting {
            return (String(localized: "connecting"), "wifi.exclamationmark", .orange)
        }
        if player.isPlaying {
            return ("Live", "antenna.radiowaves.left.and.right", .green)
        }
        return (String(localized: "paused"), "pause.fill", .secondary)
    }

    @ViewBuilder
    private var radioStatusPill: some View {
        let config = radioStatusConfiguration
        Label(config.title, systemImage: config.systemImage)
            .font(.caption)
            .foregroundStyle(config.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(config.color.opacity(0.1), in: Capsule())
    }

    private var radioPlaceholderArtwork: some View {
        ZStack {
            Color.gray.opacity(colorScheme == .dark ? 0.2 : 0.1)
            Image(systemName: "music.note.house")
                .font(.system(size: 80))
                .foregroundStyle(.gray.opacity(0.5))
        }
    }

    @ViewBuilder
    private func sleepTimerButton(size: CGFloat, isPad: Bool) -> some View {
        if let end = player.sleepTimerEnd {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(0, Int(end.timeIntervalSinceNow))
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .font(.system(size: isPad ? 13 : 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accentColor)
                    .frame(width: size, height: size)
            }
        } else {
            playerSecondaryButton(icon: "moon.zzz.fill", color: .primary, size: size, isPad: isPad)
        }
    }

    @ViewBuilder
    private func playerSecondaryButton(icon: String, color: Color, size: CGFloat, isPad: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: isPad ? 22 : 20, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }

    private func updatePlayerBackground() async {
        let key = playerBackgroundIdentifier
        guard key != "song-none", key != "radio-none" else {
            withAnimation(.easeInOut(duration: 0.5)) {
                playerBgPrimary = Color(UIColor.systemBackground)
                playerBgSecondary = Color(UIColor.systemBackground)
            }
            rawPrimary = nil
            rawSecondary = nil
            return
        }

        if let hit = Self.paletteCache.object(forKey: key as NSString) {
            rawPrimary = hit.primary
            rawSecondary = hit.secondary
            withAnimation(.easeInOut(duration: 0.6)) {
                playerBgPrimary = adaptedColor(hit.primary, asSecondary: false)
                playerBgSecondary = adaptedColor(hit.secondary ?? hit.primary, asSecondary: true)
            }
            return
        }

        let resolved = await loadPlayerBackgroundImage()
        guard !Task.isCancelled else { return }
        guard let img = resolved else {
            rawPrimary = nil
            rawSecondary = nil
            withAnimation(.easeInOut(duration: 0.5)) {
                playerBgPrimary = Color(UIColor.systemBackground)
                playerBgSecondary = Color(UIColor.systemBackground)
            }
            return
        }
        let (primary, secondary) = img.extractPlayerPalette()
        guard !Task.isCancelled else { return }
        Self.paletteCache.setObject(PlayerPaletteResult(primary, secondary), forKey: key as NSString)
        rawPrimary = primary
        rawSecondary = secondary
        withAnimation(.easeInOut(duration: 0.6)) {
            playerBgPrimary = adaptedColor(primary, asSecondary: false)
            playerBgSecondary = adaptedColor(secondary ?? primary, asSecondary: true)
        }
    }

    private func loadPlayerBackgroundImage() async -> UIImage? {
        if player.isRadioPlayback {
            return await loadRadioBackgroundImage()
        }
        guard let coverArtId = player.currentSong?.coverArt else { return nil }
        return await loadSongBackgroundImage(coverArtId: coverArtId)
    }

    private func loadSongBackgroundImage(coverArtId: String) async -> UIImage? {
        let key300 = "\(coverArtId)_300"
        let image: UIImage?
        if let cached = ImageCacheService.shared.cachedImage(key: key300) {
            image = cached
        } else if let localPath = LocalArtworkIndex.shared.localPath(for: coverArtId),
                  let local = UIImage(contentsOfFile: localPath) {
            image = local
        } else if let url = SubsonicAPIService.shared.coverArtURL(for: coverArtId, size: 300) {
            image = await ImageCacheService.shared.image(url: url, key: key300)
        } else {
            image = nil
        }

        if let image {
            return image
        } else if let url = SubsonicAPIService.shared.coverArtURL(for: coverArtId, size: 80) {
            return await ImageCacheService.shared.image(url: url, key: "\(coverArtId)_80")
        } else {
            return nil
        }
    }

    private func loadRadioBackgroundImage() async -> UIImage? {
        guard let station = player.currentRadioStation else { return nil }
        if station.usesDynamicSongCover,
           let url = player.currentRadioMetadata?.cacheBustedArtworkURL {
            let key = "radio_remote_\(url.absoluteString)"
            if let cached = ImageCacheService.shared.cachedImage(key: key) {
                return cached
            }
            if let image = await ImageCacheService.shared.image(url: url, key: key) {
                return image
            }
        }
        if let coverArtId = station.coverArt {
            return await loadSongBackgroundImage(coverArtId: coverArtId)
        }
        return nil
    }

    private func adaptedColor(_ uiColor: UIColor, asSecondary: Bool) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let factor: CGFloat = asSecondary ? 0.88 : 1.0
        if colorScheme == .dark {
            return Color(UIColor(
                hue: h,
                saturation: min(s * 1.2 * factor, 0.90),
                brightness: min(max(v, 0.35) * 0.82, 0.72),
                alpha: 1
            ))
        } else {
            return Color(UIColor(
                hue: h,
                saturation: min(s * 0.82 * factor, 0.78),
                brightness: min(v * 0.45 + 0.58, 0.96),
                alpha: 1
            ))
        }
    }

    private func resolveArtist(_ artistName: String) {
        if let found = currentArtist {
            artistDestination = found
        } else if !isResolvingArtist {
            isResolvingArtist = true
            artistResolveTask?.cancel()
            artistResolveTask = Task {
                defer { isResolvingArtist = false }
                guard !Task.isCancelled else { return }
                if let result = try? await SubsonicAPIService.shared.search(query: artistName),
                   let found = result.artist?.first(where: { $0.name.lowercased() == artistName.lowercased() })
                    ?? result.artist?.first {
                    guard !Task.isCancelled else { return }
                    artistDestination = found
                }
            }
        }
    }

    private var audioBadge: String? {
        player.actualStreamFormat?.displayString
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct RadioStationPlayerArtworkView: View {
    let coverArtId: String
    let displaySize: CGFloat
    let cornerRadius: CGFloat
    private let requestSize: Int
    @State private var image: UIImage?
    @State private var isLoading: Bool

    init(coverArtId: String, displaySize: CGFloat, cornerRadius: CGFloat) {
        self.coverArtId = coverArtId
        self.displaySize = displaySize
        self.cornerRadius = cornerRadius
        let scale = UIScreen.main.scale
        let pixelSize = Int((displaySize * scale).rounded(.up))
        self.requestSize = min(1200, max(600, pixelSize))
        let key = "\(coverArtId)_\(self.requestSize)"
        self._image = State(initialValue: ImageCacheService.shared.cachedImage(key: key))
        self._isLoading = State(initialValue: ImageCacheService.shared.cachedImage(key: key) == nil)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.16)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .tint(.secondary)
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: displaySize * 0.28, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .frame(width: displaySize, height: displaySize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: "\(coverArtId)_\(requestSize)") {
            await load()
        }
    }

    @MainActor
    private func load() async {
        let key = "\(coverArtId)_\(requestSize)"
        if let cached = ImageCacheService.shared.cachedImage(key: key) {
            image = cached
            isLoading = false
            return
        }

        #if DEBUG
        if coverArtId.hasPrefix("demo_"), let demoImage = UIImage(named: coverArtId) {
            ImageCacheService.shared.cache(demoImage, key: key)
            image = demoImage
            isLoading = false
            return
        }
        #endif

        guard let url = SubsonicAPIService.shared.coverArtURL(for: coverArtId, size: requestSize) else {
            isLoading = false
            return
        }
        isLoading = image == nil
        let loaded = await ImageCacheService.shared.image(url: url, key: key)
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
        }
        isLoading = false
    }
}

private struct SleepTimerPanel: View {
    @ObservedObject private var player = AudioPlayerService.shared
    @Environment(\.dismiss) private var dismiss

    private let options = [15, 30, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            List {
                if player.sleepTimerEnd != nil {
                    Section {
                        Button(role: .destructive) {
                            player.cancelSleepTimer()
                            dismiss()
                        } label: {
                            Text(String(localized: "cancel_timer"))
                        }
                    }
                }

                Section {
                    ForEach(options, id: \.self) { minutes in
                        Button {
                            player.setSleepTimer(minutes: minutes)
                            dismiss()
                        } label: {
                            Text(rowLabel(for: minutes))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "sleep_timer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                        .bold()
                }
            }
        }
    }

    private func rowLabel(for minutes: Int) -> String {
        switch minutes {
        case 60:
            return "1 \(String(localized: "hour_abbreviation"))"
        case 120:
            return "2 \(String(localized: "hour_abbreviation"))"
        default:
            return "\(minutes) \(String(localized: "minutes_abbreviation"))"
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .label
    var activeTintColor: UIColor = .systemBlue

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = tintColor
        picker.activeTintColor = activeTintColor
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}

private extension UIImage {
    func extractPlayerPalette() -> (UIColor, UIColor?) {
        // 14 Buckets: 0–11 = Hue (je 30°, s ≥ 0.15), 12 = Dunkel (v < 0.20), 13 = Hell (v > 0.85, s < 0.12)
        let totalBuckets = 14

        let side = 32
        let totalPixels = side * side
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let small = renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
        guard let cgImage = small.cgImage else { return (.systemGray, nil) }

        var pixels = [UInt8](repeating: 0, count: totalPixels * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (.systemGray, nil) }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var rSum = [CGFloat](repeating: 0, count: totalBuckets)
        var gSum = [CGFloat](repeating: 0, count: totalBuckets)
        var bSum = [CGFloat](repeating: 0, count: totalBuckets)
        var counts = [Int](repeating: 0, count: totalBuckets)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255
            let g = CGFloat(pixels[i+1]) / 255
            let b = CGFloat(pixels[i+2]) / 255

            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)

            let bucket: Int
            if v < 0.20 {
                bucket = 12
            } else if v > 0.85, s < 0.12 {
                bucket = 13
            } else if s >= 0.15 {
                bucket = min(Int(h * 12), 11)
            } else {
                continue
            }
            rSum[bucket] += r; gSum[bucket] += g; bSum[bucket] += b
            counts[bucket] += 1
        }

        func bucketColor(at idx: Int) -> UIColor {
            let n = CGFloat(counts[idx])
            return UIColor(red: rSum[idx]/n, green: gSum[idx]/n, blue: bSum[idx]/n, alpha: 1)
        }

        // Phase 1: chromatische Buckets (0–11) nach Grösse sortieren
        let chromaticSorted = (0..<12).filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }

        var primary: UIColor
        var secondary: UIColor? = nil

        if let primaryIdx = chromaticSorted.first {
            let chromaticColor = bucketColor(at: primaryIdx)
            let chromaticCount = counts[primaryIdx]
            let minSecondaryCount = max(3, chromaticCount / 10)

            // Zweite chromatische Farbe suchen (≥60° Hue-Abstand, ≥25% des Primär-Buckets)
            for candidateIdx in chromaticSorted.dropFirst() {
                let diff = abs(candidateIdx - primaryIdx)
                if min(diff, 12 - diff) >= 2, counts[candidateIdx] >= minSecondaryCount {
                    secondary = bucketColor(at: candidateIdx)
                    break
                }
            }

            if secondary != nil {
                // Zwei chromatische Farben → Chroma bleibt Primär
                primary = chromaticColor
            } else {
                // Neutral-Fallback: wer mehr Pixel hat, wird Primär
                let darkCount = counts[12]
                let lightCount = counts[13]
                let neutralIdx = darkCount >= lightCount ? 12 : 13
                let neutralCount = max(darkCount, lightCount)
                if neutralCount > 0 {
                    if neutralCount > chromaticCount {
                        primary = bucketColor(at: neutralIdx)
                        secondary = chromaticColor
                    } else {
                        primary = chromaticColor
                        secondary = bucketColor(at: neutralIdx)
                    }
                } else {
                    primary = chromaticColor
                }
            }
        } else {
            // Kein Chroma überhaupt → Dark vs Light
            let darkCount = counts[12]
            let lightCount = counts[13]
            if darkCount >= lightCount {
                primary = darkCount > 0 ? bucketColor(at: 12) : .systemGray
                secondary = lightCount > 0 ? bucketColor(at: 13) : nil
            } else {
                primary = bucketColor(at: 13)
                secondary = darkCount > 0 ? bucketColor(at: 12) : nil
            }
        }

        // Letzter Fallback: tonale Variante der Primärfarbe
        if secondary == nil {
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            primary.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            secondary = UIColor(
                hue: h,
                saturation: min(s * 0.8, 1.0),
                brightness: max(v * 0.45, 0.10),
                alpha: 1
            )
        }

        return (primary, secondary)
    }
}
