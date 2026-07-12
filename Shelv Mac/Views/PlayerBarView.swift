import SwiftUI
import AppKit

private enum NativeMacSliderInteraction {
    case jumpWithGrabSafety
    case grabOnly
}

private enum NativeMacSliderDragMode {
    case grab(startValue: Double)
    case jump
}

private struct NativeMacLinearSlider: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let trackColor: Color
    let fillColor: Color
    let accessibilityLabel: String
    var idleHeight: CGFloat = 5
    var activeHeight: CGFloat = 10
    var isEnabled = true
    var interaction: NativeMacSliderInteraction = .jumpWithGrabSafety
    var grabRadius: CGFloat = 18
    var grabActivationDistance: CGFloat = 2
    var layoutHeight: CGFloat = 28
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isInteracting = false
    @State private var isHovered = false
    @State private var dragMode: NativeMacSliderDragMode?

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
            .frame(height: isInteracting || isHovered ? activeHeight : idleHeight)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled, width > 0 else { return }
                        if dragMode == nil {
                            dragMode = resolvedDragMode(startX: gesture.startLocation.x, width: width)
                            guard dragMode != nil else { return }
                        }
                        guard shouldUpdateValue(for: gesture) else { return }
                        beginInteractionIfNeeded()
                        updateValue(for: gesture, width: width)
                    }
                    .onEnded { gesture in
                        guard isEnabled, width > 0 else {
                            resetInteraction(notify: isInteracting)
                            return
                        }
                        guard dragMode != nil else { return }
                        guard shouldUpdateValue(for: gesture) else {
                            resetInteraction(notify: false)
                            return
                        }
                        beginInteractionIfNeeded()
                        updateValue(for: gesture, width: width)
                        resetInteraction(notify: true)
                    }
            )
            .onHover { hovering in
                guard isEnabled else { return }
                isHovered = hovering
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isInteracting)
            .animation(.easeOut(duration: 0.14), value: isHovered)
        }
        .frame(height: layoutHeight)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int(normalizedValue * 100))%")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let span = bounds.upperBound - bounds.lowerBound
            guard span > 0 else { return }
            let step = span * 0.05
            switch direction {
            case .increment:
                value = clamped(value + step)
            case .decrement:
                value = clamped(value - step)
            @unknown default:
                break
            }
            onEditingChanged(false)
        }
    }

    private var normalizedValue: Double {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - bounds.lowerBound) / span))
    }

    private func progressWidth(in width: CGFloat) -> CGFloat {
        width * CGFloat(normalizedValue)
    }

    private func resolvedDragMode(startX: CGFloat, width: CGFloat) -> NativeMacSliderDragMode? {
        let currentX = CGFloat(normalizedValue) * width
        let startsNearCurrentValue = abs(startX - currentX) <= grabRadius
        switch interaction {
        case .jumpWithGrabSafety:
            return startsNearCurrentValue ? .grab(startValue: value) : .jump
        case .grabOnly:
            return startsNearCurrentValue ? .grab(startValue: value) : nil
        }
    }

    private func updateValue(for gesture: DragGesture.Value, width: CGFloat) {
        switch dragMode {
        case .grab(let startValue):
            updateValue(startValue: startValue, translationX: gesture.translation.width, width: width)
        case .jump:
            updateValue(at: gesture.location.x, width: width)
        case nil:
            break
        }
    }

    private func shouldUpdateValue(for gesture: DragGesture.Value) -> Bool {
        switch dragMode {
        case .grab:
            let distance = hypot(gesture.translation.width, gesture.translation.height)
            return distance >= grabActivationDistance
        case .jump:
            return true
        case nil:
            return false
        }
    }

    private func beginInteractionIfNeeded() {
        guard !isInteracting else { return }
        isInteracting = true
        onEditingChanged(true)
    }

    private func resetInteraction(notify: Bool) {
        dragMode = nil
        if isInteracting {
            isInteracting = false
            if notify {
                onEditingChanged(false)
            }
        }
    }

    private func updateValue(at locationX: CGFloat, width: CGFloat) {
        let fraction = min(1, max(0, Double(locationX / width)))
        value = bounds.lowerBound + (bounds.upperBound - bounds.lowerBound) * fraction
    }

    private func updateValue(startValue: Double, translationX: CGFloat, width: CGFloat) {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return }
        let translatedValue = startValue + Double(translationX / width) * span
        value = clamped(translatedValue)
    }

    private func clamped(_ candidate: Double) -> Double {
        min(bounds.upperBound, max(bounds.lowerBound, candidate))
    }
}

struct PlayerBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var radioStore = RadioStationStore.shared

    private var audioBadge: String? {
        player.actualStreamFormat?.displayString
    }
    @Environment(\.themeColor) private var themeColor
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.miniPlayerStyle) private var interfaceStyleRaw = PersonalizationMiniPlayerStyle.shelv.rawValue
    @AppStorage("radioSortDirectionMac") private var radioSortDirectionRaw = SortDirection.ascending.rawValue
    @State private var isDragging: Bool = false
    @State private var dragValue: Double = 0
    // currentTime ist kein @Published → das Zeit-Label/der Slider werden über den
    // timePublisher gespeist. Ohne das friert die Anzeige ein (z.B. nach einem Seek),
    // obwohl der Ton normal weiterläuft.
    @State private var displayTime: Double = 0
    @State private var lastAudibleVolume: Float = 0.7
    @State private var isSleepTimerMenuPresented: Bool = false

    private var radioDisplayItems: [RadioStationDisplayItem] {
        let direction = SortDirection(rawValue: radioSortDirectionRaw) ?? .ascending
        return direction == .descending ? Array(radioStore.items.reversed()) : radioStore.items
    }

    private var usesNativeInterface: Bool {
        PersonalizationMiniPlayerStyle(rawValue: interfaceStyleRaw) == .native
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    Group {
                        if let station = player.currentRadioStation {
                            MacRadioStationArtworkView(
                                item: station,
                                size: 62,
                                metadata: player.currentRadioMetadata,
                                reloadToken: player.artworkReloadToken
                            )
                        } else if let song = player.currentSong, let coverID = song.coverArt,
                           let url = SubsonicAPIService.shared.coverArtURL(id: coverID, size: 120) {
                            CoverArtView(url: url, size: 62, cornerRadius: 8)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.secondary.opacity(0.15))
                                Image(systemName: "music.note")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 62, height: 62)
                        }
                    }

                    if let song = player.currentSong {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                appState.showSongInfo(song)
                            } label: {
                                Text(song.title)
                                    .font(.body.bold())
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(appState.activePanel == .songInfo ? themeColor : .primary)
                            .help(String(localized: "song_info"))
                            .onHover { inside in
                                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                            HStack(spacing: 0) {
                                if let id = song.artistId, let name = song.artist {
                                    Button(name) {
                                        appState.selectedPlaylist = nil
                                        appState.selectedSidebar = .artists
                                        appState.navigationPath = NavigationPath()
                                        appState.navigationPath.append(
                                            Artist(id: id, name: name, albumCount: nil, coverArt: nil, starred: nil)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(themeColor)
                                    .onHover { inside in
                                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                    }
                                } else if let name = song.artist {
                                    Text(name).foregroundStyle(.secondary)
                                }
                                if song.artist != nil && song.album != nil {
                                    Text(" · ").foregroundStyle(.secondary)
                                }
                                if let id = song.albumId, let name = song.album {
                                    Button(name) {
                                        appState.selectedPlaylist = nil
                                        appState.selectedSidebar = .albums
                                        appState.navigationPath = NavigationPath()
                                        appState.navigationPath.append(
                                            Album(id: id, name: name, artist: song.artist,
                                                  artistId: song.artistId, coverArt: song.coverArt)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(themeColor)
                                    .onHover { inside in
                                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                    }
                                } else if let name = song.album {
                                    Text(name).foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                            .lineLimit(1)
                        }
                    } else if player.isRadioPlayback {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.displayTitle)
                                .font(.body.bold())
                                .lineLimit(1)
                            Text(player.displaySubtitleLine)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(String(localized: "no_track"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)

                VStack(spacing: Self.centerStackSpacing) {
                    Group {
                        if player.isRadioPlayback {
                            radioTransportControls
                        } else {
                            HStack(spacing: 22) {
                                Group {
                                    if showPlaylistActions, let song = player.currentSong {
                                        Button {
                                            NotificationCenter.default.post(name: .addSongsToPlaylist, object: [song.id])
                                        } label: {
                                            Image(systemName: "music.note.list")
                                                .foregroundStyle(AnyShapeStyle(.primary.opacity(0.35)))
                                        }
                                        .buttonStyle(.plain)
                                        .help(String(localized: "add_to_playlist"))
                                    } else {
                                        Image(systemName: "music.note.list")
                                            .hidden()
                                    }
                                }
                                .font(.title2)

                                if player.isRadioPlayback {
                                    Image(systemName: "shuffle")
                                        .hidden()
                                        .font(.title2)
                                } else {
                                    Button { player.toggleShuffle() } label: {
                                        Image(systemName: "shuffle")
                                            .foregroundStyle(player.isShuffled ? AnyShapeStyle(themeColor) : AnyShapeStyle(.primary.opacity(0.35)))
                                    }
                                    .buttonStyle(.plain)
                                    .font(.title2)
                                    .help(player.isShuffled ? String(localized: "shuffle_off") : String(localized: "shuffle_on"))
                                }

                                if player.isRadioPlayback {
                                    Button { player.playPreviousRadioStation(in: radioDisplayItems) } label: {
                                        Image(systemName: "backward.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .font(.title2)
                                    .disabled(radioDisplayItems.count <= 1)
                                } else {
                                    Button { player.previous() } label: {
                                        Image(systemName: "backward.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .font(.title2)
                                    .disabled(player.queue.isEmpty)
                                }

                                Button { player.togglePlayPause() } label: {
                                    ZStack {
                                        Circle().fill(themeColor)
                                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                            .foregroundStyle(.white)
                                            .font(.system(size: 17, weight: .semibold))
                                            .offset(x: player.isPlaying ? 0 : 1.5)
                                    }
                                    .frame(width: 46, height: 46)
                                }
                                .buttonStyle(.plain)
                                .disabled(!player.hasActivePlayback)

                                if player.isRadioPlayback {
                                    Button { player.playNextRadioStation(in: radioDisplayItems) } label: {
                                        Image(systemName: "forward.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .font(.title2)
                                    .disabled(radioDisplayItems.count <= 1)
                                } else {
                                    Button { player.next(triggeredByUser: true) } label: {
                                        Image(systemName: "forward.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .font(.title2)
                                    .disabled(player.repeatMode == .off
                                        && player.currentIndex >= player.queue.count - 1
                                        && player.playNextQueue.isEmpty
                                        && player.userQueue.isEmpty)
                                }

                                if player.isRadioPlayback {
                                    Image(systemName: player.repeatMode.systemImage)
                                        .hidden()
                                        .font(.title2)
                                } else {
                                    Button { player.cycleRepeatMode() } label: {
                                        Image(systemName: player.repeatMode.systemImage)
                                            .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.primary.opacity(0.35)) : AnyShapeStyle(themeColor))
                                    }
                                    .buttonStyle(.plain)
                                    .font(.title2)
                                    .help(repeatHelpText)
                                }

                                Group {
                                    if showFavoriteActions, let song = player.currentSong {
                                        let isStarred = libraryStore.isSongStarred(song)
                                        Button {
                                            Task {
                                                await libraryStore.toggleStarSong(song)
                                                player.setCurrentSongStarred(!isStarred)
                                            }
                                        } label: {
                                            Image(systemName: isStarred ? "heart.fill" : "heart")
                                                .foregroundStyle(isStarred ? AnyShapeStyle(themeColor) : AnyShapeStyle(.primary.opacity(0.35)))
                                        }
                                        .buttonStyle(.plain)
                                        .help(isStarred
                                              ? String(localized: "remove_from_favorites")
                                              : String(localized: "add_to_favorites"))
                                    } else {
                                        Image(systemName: "heart")
                                            .hidden()
                                    }
                                }
                                .font(.title2)
                            }
                        }
                    }
                    .frame(height: Self.transportControlsHeight)

                    Group {
                        if player.isRadioPlayback {
                            liveStatusView
                        } else {
                            HStack(spacing: 10) {
                                Text(formatTime(isDragging ? dragValue : displayTime))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 42, alignment: .trailing)

                                playbackProgressControl

                                Text(formatTime(player.duration))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 42, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: Self.progressRowHeight)
                }
                .frame(height: Self.centerStackHeight)
                .frame(maxWidth: 560)

                HStack(spacing: 12) {
                    if player.isRadioPlayback {
                        Text(player.radioDisplayStationName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 170, alignment: .trailing)
                            .padding(.trailing, 8)
                    } else {
                        HStack(spacing: 5) {
                            if player.showBufferingIndicator {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 14, height: 14)
                            }
                            Text(player.showBufferingIndicator ? String(localized: "loading_2") : (audioBadge ?? ""))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 14)
                        .padding(.trailing, 8)

                        MacPlayerUtilityButton(
                            systemName: "list.bullet",
                            isActive: appState.activePanel == .queue,
                            helpText: String(localized: "queue"),
                            iconSize: Self.rightIconSize + 1
                        ) {
                            appState.togglePanel(.queue)
                        }

                        MacPlayerUtilityButton(
                            systemName: "quote.bubble",
                            isActive: appState.activePanel == .lyrics,
                            helpText: String(localized: "lyrics")
                        ) {
                            appState.togglePanel(.lyrics)
                        }
                    }

                    MacRoutePickerButton()

                    MacPlayerUtilityButton(
                        systemName: volumeSystemImage,
                        isActive: false,
                        helpText: player.volume < 0.01 ? String(localized: "unmute") : String(localized: "mute"),
                        weight: .regular
                    ) {
                        toggleMute()
                    }

                    volumeControl
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 20)
            }
            .frame(height: 100)
        }
        .background(.bar)
        .onReceive(player.timePublisher) { update in
            guard !isDragging else { return }
            displayTime = update.time
        }
        .onAppear {
            displayTime = player.currentTime
            rememberAudibleVolume(player.volume)
        }
        .onChange(of: player.currentSong?.id ?? player.currentRadioStation?.id) { _, _ in displayTime = player.currentTime }
        .onChange(of: player.volume) { _, newVolume in
            rememberAudibleVolume(newVolume)
        }
    }

    @ViewBuilder
    private var playbackProgressControl: some View {
        if usesNativeInterface {
            NativeMacLinearSlider(
                value: progressBinding,
                bounds: 0...max(player.duration, 1),
                trackColor: Color.primary.opacity(0.16),
                fillColor: Color.primary.opacity(0.86),
                accessibilityLabel: String(localized: "playback_position"),
                idleHeight: 5,
                activeHeight: 10,
                isEnabled: player.currentSong != nil && player.duration > 0,
                interaction: .jumpWithGrabSafety,
                grabRadius: 10,
                layoutHeight: Self.nativePlaybackSliderHeight,
                onEditingChanged: handleSeekEditing
            )
            .frame(maxWidth: 360)
        } else {
            Slider(
                value: progressBinding,
                in: 0...max(player.duration, 1),
                onEditingChanged: handleSeekEditing
            )
            .frame(maxWidth: 360)
            .disabled(player.currentSong == nil || player.duration <= 0)
        }
    }

    @ViewBuilder
    private var volumeControl: some View {
        if usesNativeInterface {
            NativeMacLinearSlider(
                value: volumeBinding,
                bounds: 0...1,
                trackColor: Color.primary.opacity(0.16),
                fillColor: Color.primary.opacity(0.86),
                accessibilityLabel: String(localized: "volume"),
                idleHeight: 5,
                activeHeight: 9,
                interaction: .jumpWithGrabSafety,
                grabRadius: 10
            )
            .frame(width: 100)
            .padding(.leading, -4)
        } else {
            Slider(value: volumeBinding, in: 0...1)
                .frame(width: 100)
                .padding(.leading, -4)
        }
    }

    private var liveStatusView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(radioStatusColor)
                .frame(width: 7, height: 7)
            Text(player.radioStatusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 454, minHeight: 20)
    }

    private var radioStatusColor: Color {
        player.isRadioConnecting ? .orange : (player.isPlaying ? .green : .secondary)
    }

    private var radioTransportControls: some View {
        HStack(spacing: 18) {
            sleepTimerMenu

            Button { player.playPreviousRadioStation(in: radioDisplayItems) } label: {
                Image(systemName: "backward.fill")
                    .foregroundStyle(radioDisplayItems.count > 1 ? Color.primary : Color.secondary.opacity(0.45))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .font(.title2)
            .disabled(radioDisplayItems.count <= 1)
            .help(String(localized: "previous"))

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(themeColor)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 17, weight: .semibold))
                        .offset(x: player.isPlaying ? 0 : 1.5)
                }
                .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasActivePlayback)

            Button { player.playNextRadioStation(in: radioDisplayItems) } label: {
                Image(systemName: "forward.fill")
                    .foregroundStyle(radioDisplayItems.count > 1 ? Color.primary : Color.secondary.opacity(0.45))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .font(.title2)
            .disabled(radioDisplayItems.count <= 1)
            .help(String(localized: "next"))

            Button { player.stop() } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .font(.title2)
            .help("Stop")
        }
    }

    private var sleepTimerMenu: some View {
        sleepTimerMenuLabel
        .frame(width: 30, height: 28)
        .contentShape(Rectangle())
        .help(String(localized: "sleep_timer"))
        .overlay {
            SleepTimerNativeMenuTrigger(
                options: Self.sleepTimerOptions,
                showsCancel: player.sleepTimerEnd != nil,
                cancelTitle: String(localized: "cancel_timer"),
                titleForOption: sleepTimerRowLabel(minutes:),
                isPresented: $isSleepTimerMenuPresented,
                onCancel: { player.cancelSleepTimer() },
                onSelect: { player.setSleepTimer(minutes: $0) }
            )
        }
    }

    @ViewBuilder
    private var sleepTimerMenuLabel: some View {
        let foregroundColor: Color = isSleepTimerMenuPresented ? themeColor : .secondary

        if let end = player.sleepTimerEnd {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(0, Int(end.timeIntervalSinceNow))
                Text(formatSleepTimer(remaining))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 30, height: 28)
            }
        } else {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(foregroundColor)
                .frame(width: 30, height: 28)
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(player.volume) },
            set: { newValue in
                player.volume = Float(newValue)
            }
        )
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { isDragging ? dragValue : displayTime },
            set: { dragValue = $0 }
        )
    }

    private func handleSeekEditing(_ editing: Bool) {
        if editing {
            isDragging = true
            dragValue = displayTime
        } else {
            player.seek(to: dragValue)
            displayTime = dragValue
            isDragging = false
        }
    }

    private var volumeSystemImage: String {
        if player.volume < 0.01 {
            return "speaker.slash.fill"
        }
        if player.volume < 0.5 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.3.fill"
    }

    private func toggleMute() {
        if player.volume < 0.01 {
            player.volume = max(lastAudibleVolume, 0.25)
        } else {
            rememberAudibleVolume(player.volume)
            player.volume = 0
        }
    }

    private func rememberAudibleVolume(_ volume: Float) {
        if volume >= 0.01 {
            lastAudibleVolume = volume
        }
    }

    private var repeatHelpText: String {
        switch player.repeatMode {
        case .off: return String(localized: "repeat_off")
        case .all: return String(localized: "repeat_all")
        case .one: return String(localized: "repeat_one")
        }
    }

    fileprivate static let rightControlSize: CGFloat = 30
    fileprivate static let rightIconSize: CGFloat = 17
    fileprivate static let routePickerSize: CGFloat = 20
    private static let transportControlsHeight: CGFloat = 46
    private static let progressRowHeight: CGFloat = 22
    private static let centerStackSpacing: CGFloat = 8
    private static let centerStackHeight = transportControlsHeight + centerStackSpacing + progressRowHeight
    private static let nativePlaybackSliderHeight: CGFloat = 20
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
        if seconds >= 3600 {
            let totalMinutes = Int(ceil(Double(seconds) / 60))
            return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

}

private struct MacPlayerUtilityButton: View {
    let systemName: String
    let isActive: Bool
    let helpText: String
    var iconSize: CGFloat = PlayerBarView.rightIconSize
    var weight: Font.Weight = .medium
    let action: () -> Void

    @Environment(\.themeColor) private var themeColor
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: iconSize, weight: weight))
                .foregroundStyle(foregroundColor)
                .frame(width: PlayerBarView.rightControlSize, height: PlayerBarView.rightControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var foregroundColor: Color {
        if isActive {
            return themeColor
        }
        return isHovered ? .primary : .secondary
    }
}

private struct MacRoutePickerButton: View {
    @Environment(\.themeColor) private var themeColor
    @State private var isHovered = false

    var body: some View {
        ZStack {
            if isHovered {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }

            AVRoutePickerViewRepresentable(activeColor: NSColor(themeColor))
                .frame(width: PlayerBarView.routePickerSize, height: PlayerBarView.routePickerSize)
        }
        .frame(width: PlayerBarView.rightControlSize, height: PlayerBarView.rightControlSize)
        .contentShape(Rectangle())
        .help(String(localized: "airplay"))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct SleepTimerNativeMenuTrigger: NSViewRepresentable {
    let options: [Int]
    let showsCancel: Bool
    let cancelTitle: String
    let titleForOption: (Int) -> String
    @Binding var isPresented: Bool
    let onCancel: () -> Void
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TriggerView {
        let view = TriggerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TriggerView, context: Context) {
        context.coordinator.parent = self
        nsView.coordinator = context.coordinator
    }

    final class TriggerView: NSView {
        weak var coordinator: Coordinator?

        override func mouseDown(with event: NSEvent) {
            coordinator?.showMenu(from: self)
        }

        override func rightMouseDown(with event: NSEvent) {
            coordinator?.showMenu(from: self)
        }
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: SleepTimerNativeMenuTrigger

        init(parent: SleepTimerNativeMenuTrigger) {
            self.parent = parent
        }

        func showMenu(from view: NSView) {
            parent.isPresented = true

            let menu = NSMenu()
            menu.delegate = self

            if parent.showsCancel {
                let item = NSMenuItem(title: parent.cancelTitle, action: #selector(cancelSleepTimer), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                menu.addItem(item)
                menu.addItem(.separator())
            }

            for minutes in parent.options {
                let item = NSMenuItem(title: parent.titleForOption(minutes), action: #selector(selectSleepTimerOption(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = minutes
                menu.addItem(item)
            }

            let menuWidth: CGFloat = 132
            menu.minimumWidth = menuWidth
            let x = view.bounds.midX - (menuWidth / 2)
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: -12), in: view)
        }

        func menuDidClose(_ menu: NSMenu) {
            parent.isPresented = false
        }

        @objc private func cancelSleepTimer() {
            parent.onCancel()
        }

        @objc private func selectSleepTimerOption(_ sender: NSMenuItem) {
            guard let minutes = sender.representedObject as? Int else { return }
            parent.onSelect(minutes)
        }
    }
}

#Preview {
    PlayerBarView()
        .environmentObject(AppState.shared)
        .environmentObject(LibraryViewModel())
        .frame(width: 1000)
}
