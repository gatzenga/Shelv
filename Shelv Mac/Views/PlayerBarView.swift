import SwiftUI
import AppKit

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

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    Group {
                        if let station = player.currentRadioStation {
                            MacRadioStationArtworkView(item: station, size: 62, metadata: player.currentRadioMetadata)
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
                            Text(song.title)
                                .font(.body.bold())
                                .lineLimit(1)
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

                VStack(spacing: 10) {
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

                                Slider(
                                    value: Binding(
                                        get: { isDragging ? dragValue : displayTime },
                                        set: { newVal in dragValue = newVal }
                                    ),
                                    in: 0...max(player.duration, 1)
                                ) { editing in
                                    if editing {
                                        isDragging = true
                                    } else {
                                        player.seek(to: dragValue)
                                        displayTime = dragValue
                                        isDragging = false
                                    }
                                }
                                .frame(maxWidth: 360)
                                .disabled(player.currentSong == nil || player.duration <= 0)

                                Text(formatTime(player.duration))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 42, alignment: .leading)
                            }
                        }
                    }
                }
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

                        Button { appState.togglePanel(.queue) } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: Self.rightIconSize + 1, weight: .medium))
                                .foregroundStyle(appState.activePanel == .queue ? themeColor : Color.secondary)
                                .frame(width: Self.rightControlSize, height: Self.rightControlSize)
                        }
                        .buttonStyle(.plain)
                        .frame(width: Self.rightControlSize, height: Self.rightControlSize)
                        .help(String(localized: "queue"))

                        Button { appState.togglePanel(.lyrics) } label: {
                            Image(systemName: "text.quote")
                                .font(.system(size: Self.rightIconSize, weight: .medium))
                                .foregroundStyle(appState.activePanel == .lyrics ? themeColor : Color.secondary)
                                .frame(width: Self.rightControlSize, height: Self.rightControlSize)
                        }
                        .buttonStyle(.plain)
                        .frame(width: Self.rightControlSize, height: Self.rightControlSize)
                        .help(String(localized: "lyrics"))
                    }

                    AVRoutePickerViewRepresentable()
                        .frame(width: 22, height: 22)
                        .frame(width: Self.rightControlSize, height: Self.rightControlSize)
                        .help(String(localized: "airplay"))

                    HStack(spacing: 8) {
                        Button { toggleMute() } label: {
                            Image(systemName: volumeSystemImage)
                                .font(.system(size: Self.rightIconSize, weight: .regular))
                                .foregroundStyle(Color.secondary)
                                .frame(width: Self.rightControlSize, height: Self.rightControlSize)
                        }
                        .buttonStyle(.plain)
                        .frame(width: Self.rightControlSize, height: Self.rightControlSize)
                        .help(player.volume < 0.01 ? String(localized: "unmute") : String(localized: "mute"))

                        Slider(value: volumeBinding, in: 0...1)
                            .frame(width: 100)
                    }
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

    private static let rightControlSize: CGFloat = 28
    private static let rightIconSize: CGFloat = 17
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
