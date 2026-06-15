import SwiftUI
import AVKit
import Combine

struct PlayerBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @EnvironmentObject var lyricsStore: LyricsStore
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject private var player = AudioPlayerService.shared

    private var audioBadge: String? {
        player.actualStreamFormat?.displayString
    }
    @Environment(\.themeColor) private var themeColor
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true
    @State private var isDragging: Bool = false
    @State private var dragValue: Double = 0
    // currentTime ist kein @Published → das Zeit-Label/der Slider werden über den
    // timePublisher gespeist. Ohne das friert die Anzeige ein (z.B. nach einem Seek),
    // obwohl der Ton normal weiterläuft.
    @State private var displayTime: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    Group {
                        if let song = player.currentSong, let coverID = song.coverArt,
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
                    } else {
                        Text(String(localized: "no_track"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)

                VStack(spacing: 10) {
                    HStack(spacing: 22) {
                        Group {
                            if enablePlaylists, let song = player.currentSong {
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

                        Button { player.toggleShuffle() } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(player.isShuffled ? AnyShapeStyle(themeColor) : AnyShapeStyle(.primary.opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                        .font(.title2)
                        .help(player.isShuffled ? String(localized: "shuffle_off") : String(localized: "shuffle_on"))

                        Button { player.previous() } label: {
                            Image(systemName: "backward.fill")
                        }
                        .buttonStyle(.plain)
                        .font(.title2)
                        .disabled(player.queue.isEmpty)

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
                        .disabled(player.currentSong == nil)

                        Button { player.next(triggeredByUser: true) } label: {
                            Image(systemName: "forward.fill")
                        }
                        .buttonStyle(.plain)
                        .font(.title2)
                        .disabled(player.repeatMode == .off
                            && player.currentIndex >= player.queue.count - 1
                            && player.playNextQueue.isEmpty
                            && player.userQueue.isEmpty)

                        Button { player.cycleRepeatMode() } label: {
                            Image(systemName: player.repeatMode.systemImage)
                                .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.primary.opacity(0.35)) : AnyShapeStyle(themeColor))
                        }
                        .buttonStyle(.plain)
                        .font(.title2)
                        .help(repeatHelpText)

                        Group {
                            if enableFavorites, let song = player.currentSong {
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
                .frame(maxWidth: 560)

                HStack(spacing: 16) {
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
                            .font(.system(size: 16))
                            .foregroundStyle(appState.activePanel == .queue ? themeColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
                    .help(String(localized: "queue"))

                    Button { appState.togglePanel(.lyrics) } label: {
                        Image(systemName: "text.quote")
                            .font(.system(size: 16))
                            .foregroundStyle(appState.activePanel == .lyrics ? themeColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
                    .help(String(localized: "lyrics"))

                    AVRoutePickerViewRepresentable()
                        .frame(width: 20, height: 20)
                        .help(String(localized: "airplay"))

                    Image(systemName: player.volume < 0.01 ? "speaker.slash.fill"
                                    : player.volume < 0.5  ? "speaker.wave.1.fill"
                                                           : "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                    Slider(value: Binding(
                        get: { Double(player.volume) },
                        set: { player.volume = Float($0) }
                    ), in: 0...1)
                    .frame(width: 100)
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
        .onAppear { displayTime = player.currentTime }
        .onChange(of: player.currentSong?.id) { _, _ in displayTime = player.currentTime }
        .task(id: player.currentSong?.id) {
            guard autoFetchLyrics,
                  let song = player.currentSong,
                  let serverId = appState.serverStore.activeServerID?.uuidString
            else {
                lyricsStore.currentLyrics = nil
                lyricsStore.isLoadingLyrics = false
                return
            }
            lyricsStore.loadLyrics(for: song, serverId: serverId)
        }
    }

    private var repeatHelpText: String {
        switch player.repeatMode {
        case .off: return String(localized: "repeat_off")
        case .all: return String(localized: "repeat_all")
        case .one: return String(localized: "repeat_one")
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

}

private struct QueueEntry: Identifiable {
    let id: String
    let index: Int
    let song: Song
}

struct QueuePopover: View {
    private let player = AudioPlayerService.shared
    @Environment(\.themeColor) private var themeColor
    @State private var showClearConfirm = false
    @State private var isEditing = false
    @AppStorage("infinityModeEnabled") private var infinityMode = false

    @State private var playNextEntries: [QueueEntry]
    @State private var albumEntries: [QueueEntry]
    @State private var userQueueEntries: [QueueEntry]
    @State private var isShuffled: Bool
    @State private var cancellables: Set<AnyCancellable> = []

    init() {
        // Snapshot synchron im init berechnen, damit der vollständige Inhalt schon
        // beim ersten Frame existiert und komplett mit der Panel-Transition mitslidet.
        // Würde der Inhalt erst in onAppear gefüllt, wechselte er mitten in der
        // laufenden Transition von Placeholder zu Liste — der neue Inhalt erschiene
        // dann sofort an seiner Endposition statt mitzuschieben.
        let snap = Self.snapshot(from: AudioPlayerService.shared)
        _isShuffled = State(initialValue: snap.isShuffled)
        _playNextEntries = State(initialValue: snap.playNext)
        _albumEntries = State(initialValue: snap.album)
        _userQueueEntries = State(initialValue: snap.userQueue)
    }

    private struct QueueSnapshot {
        var isShuffled: Bool
        var playNext: [QueueEntry]
        var album: [QueueEntry]
        var userQueue: [QueueEntry]
    }

    private static func snapshot(from player: AudioPlayerService) -> QueueSnapshot {
        let playNext = player.playNextQueue.enumerated().map {
            QueueEntry(id: "pn-\($0.offset)", index: $0.offset, song: $0.element)
        }
        let start = player.currentIndex + 1
        let album: [QueueEntry]
        if start < player.queue.count {
            album = Array(player.queue[start...]).enumerated().map { offset, song in
                QueueEntry(id: "alb-\(start + offset)-\(song.id)", index: start + offset, song: song)
            }
        } else {
            album = []
        }
        let userQueue = player.userQueue.enumerated().map {
            QueueEntry(id: "uq-\($0.offset)", index: $0.offset, song: $0.element)
        }
        return QueueSnapshot(isShuffled: player.isShuffled, playNext: playNext,
                             album: album, userQueue: userQueue)
    }

    private func rebuildEntries() {
        let snap = Self.snapshot(from: player)
        isShuffled = snap.isShuffled
        playNextEntries = snap.playNext
        albumEntries = snap.album
        userQueueEntries = snap.userQueue
    }

    private func subscribe() {
        guard cancellables.isEmpty else { return }
        Publishers.MergeMany(
            player.$queue.map { _ in () }.eraseToAnyPublisher(),
            player.$playNextQueue.map { _ in () }.eraseToAnyPublisher(),
            player.$userQueue.map { _ in () }.eraseToAnyPublisher(),
            player.$currentIndex.map { _ in () }.eraseToAnyPublisher(),
            player.$isShuffled.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { _ in rebuildEntries() }
        .store(in: &cancellables)
    }

    private var hasUpcoming: Bool {
        if isShuffled {
            return !playNextEntries.isEmpty || !albumEntries.isEmpty
        }
        return !playNextEntries.isEmpty || !albumEntries.isEmpty || !userQueueEntries.isEmpty
    }

    private var totalCount: Int {
        if isShuffled {
            return playNextEntries.count + albumEntries.count
        }
        return playNextEntries.count + albumEntries.count + userQueueEntries.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Text(String(localized: "queue")).font(.headline)
                    if totalCount > 0 {
                        Text("\(totalCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Spacer()
                if hasUpcoming {
                    Button(isEditing ? String(localized: "done") : String(localized: "edit")) {
                        isEditing.toggle()
                    }
                    .font(.caption)
                    .foregroundStyle(isEditing ? themeColor : .secondary)
                    .buttonStyle(.plain)

                    Button(String(localized: "clear")) { showClearConfirm = true }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Toggle(isOn: $infinityMode) {
                Label(String(localized: "infinity_mode"), systemImage: "infinity")
            }
            .toggleStyle(.switch)
            .tint(themeColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .onChange(of: infinityMode) { _, on in
                if on { player.topUpInfinityIfNeeded(startIfIdle: true) }
            }

            Divider()

            if !hasUpcoming {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet").font(.title2).foregroundStyle(.tertiary)
                    Text(String(localized: "no_upcoming_tracks")).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if isShuffled {
                        queueSection(String(localized: "play_next"), entries: playNextEntries,
                            onTap:   { player.jumpToPlayNext(at: $0.index) },
                            onDelete: { player.removeFromPlayNextQueue(at: $0.index) },
                            onMove:  { player.moveInPlayNextQueue(from: $0, to: $1) })

                        queueSection(String(localized: "shuffled_queue"), entries: albumEntries,
                            onTap:   { player.jumpToQueueTrack(at: $0.index) },
                            onDelete: { player.removeFromPlayQueue(at: $0.index) },
                            onMove:  { player.moveInQueue(from: $0, to: $1) })
                    } else {
                        queueSection(String(localized: "play_next"), entries: playNextEntries,
                            onTap:   { player.jumpToPlayNext(at: $0.index) },
                            onDelete: { player.removeFromPlayNextQueue(at: $0.index) },
                            onMove:  { player.moveInPlayNextQueue(from: $0, to: $1) })

                        queueSection(String(localized: "up_next"), entries: albumEntries,
                            onTap:   { player.jumpToQueueTrack(at: $0.index) },
                            onDelete: { player.removeFromPlayQueue(at: $0.index) },
                            onMove:  { player.moveInQueue(from: $0, to: $1) })

                        queueSection(String(localized: "your_queue"), entries: userQueueEntries,
                            onTap:   { player.jumpToUserQueue(at: $0.index) },
                            onDelete: { player.removeFromUserQueue(at: $0.index) },
                            onMove:  { player.moveInUserQueue(from: $0, to: $1) })
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .tint(themeColor)
            }
        }
        .alert(String(localized: "clear_queue"), isPresented: $showClearConfirm) {
            Button(String(localized: "clear"), role: .destructive) {
                player.clearUpcomingPlayQueue()
                player.clearUserQueue()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "all_upcoming_songs_will_be_removed_from_the_queue"))
        }
        .onAppear {
            rebuildEntries()
            subscribe()
        }
    }

    @ViewBuilder
    private func queueSection(
        _ title: String,
        entries: [QueueEntry],
        onTap: @escaping (QueueEntry) -> Void,
        onDelete: @escaping (QueueEntry) -> Void,
        onMove: @escaping (IndexSet, Int) -> Void
    ) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    Group {
                        if isEditing {
                            QueueSongRow(song: entry.song, isEditing: true, onDelete: { onDelete(entry) })
                        } else {
                            QueueSongRow(song: entry.song, isEditing: false, onDelete: { onDelete(entry) })
                                .contentShape(Rectangle())
                                .onTapGesture { onTap(entry) }
                        }
                    }
                    .moveDisabled(!isEditing)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }
                .onMove(perform: onMove)
            }
            .listSectionSeparator(.hidden)
        }
    }
}

struct QueueSongRow: View {
    let song: Song
    var isEditing: Bool = false
    var onDelete: (() -> Void)? = nil

    @Environment(\.themeColor) private var themeColor
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            CoverArtView(
                url: song.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 80) },
                size: 36,
                cornerRadius: 4
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.callout).lineLimit(1)
                if let artist = song.artist {
                    Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isEditing {
                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .frame(width: 22, height: 22)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
                Image(systemName: "line.3.horizontal")
                    .font(.body)
                    .foregroundStyle(themeColor)
            } else {
                Text(song.durationString).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

struct AVRoutePickerViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

#Preview {
    PlayerBarView()
        .environmentObject(AppState.shared)
        .environmentObject(LibraryViewModel())
        .frame(width: 1000)
}
