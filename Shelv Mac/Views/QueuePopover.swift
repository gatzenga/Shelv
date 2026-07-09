import Combine
import SwiftUI

private struct QueueEntry: Identifiable {
    let id: String
    let index: Int
    let song: Song
}

struct QueuePopover: View {
    private let player = AudioPlayerService.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.themeColor) private var themeColor
    @State private var showClearConfirm = false
    @State private var isEditing = false
    @State private var isEditHovered = false
    @State private var isClearHovered = false
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
                HStack(spacing: 8) {
                    if hasUpcoming {
                        Button(isEditing ? String(localized: "done") : String(localized: "edit")) {
                            isEditing.toggle()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isEditing || isEditHovered ? themeColor : .secondary)
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            isEditHovered = inside
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }

                        Button(String(localized: "clear")) { showClearConfirm = true }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isClearHovered ? themeColor : .secondary)
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                isClearHovered = inside
                                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                    }

                    MacSidePanelCloseButton {
                        appState.closePanel(.queue)
                    }
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
