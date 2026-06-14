import SwiftUI

struct QueueView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColor = "violet"
    private var accent: Color { AppTheme.color(for: themeColor) }

    private enum QSection { case playNext, album, user }

    @State private var isEditing = false
    /// Song-ID, die gerade „aufgenommen" ist und mit Hoch/Runter verschoben wird.
    @State private var picked: String? = nil

    // Lokale Spiegel für flüssiges Reordering (wie iOS).
    @State private var playNext: [Song] = []
    @State private var album: [Song] = []
    @State private var userQ: [Song] = []

    private var isEmpty: Bool { playNext.isEmpty && album.isEmpty && userQ.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isEmpty {
                ContentUnavailableView(String(localized: "queue_empty"), systemImage: "music.note.list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !playNext.isEmpty {
                            sectionHeader(String(localized: "play_next"))
                            rows(playNext, .playNext)
                        }
                        if !album.isEmpty {
                            sectionHeader(String(localized: "up_next"))
                            rows(album, .album)
                        }
                        if !userQ.isEmpty {
                            sectionHeader(String(localized: "your_queue"))
                            rows(userQ, .user)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.hidden)
                .edgeFadeMask(fade: 0.04)
            }
        }
        .task { sync() }
        .onChange(of: player.playNextQueue) { _, _ in sync() }
        .onChange(of: player.userQueue) { _, _ in sync() }
        .onChange(of: player.queue) { _, _ in sync() }
        .onChange(of: player.currentIndex) { _, _ in sync() }
    }

    // MARK: - Kopf (Edit-Stift rechts)

    private var header: some View {
        HStack {
            Spacer()
            Button {
                picked = nil
                withAnimation { isEditing.toggle() }
            } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 36)
        .padding(.top, 12)
        .focusSection()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3).bold()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 36)
            .padding(.top, 20)
            .padding(.bottom, 4)
    }

    private func rows(_ songs: [Song], _ section: QSection) -> some View {
        ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
            QueueRow(
                song: song,
                isEditing: isEditing,
                isPicked: picked == song.id,
                accent: accent,
                onSelect: {
                    if isEditing {
                        picked = (picked == song.id) ? nil : song.id
                    } else {
                        jump(section, index: i)
                    }
                },
                onMove: { up in move(section, id: song.id, up: up) },
                onDelete: { delete(section, index: i) }
            )
        }
        .focusSection()
    }

    // MARK: - Aktionen

    private func sync() {
        playNext = player.playNextQueue
        userQ = player.userQueue
        let start = player.currentIndex + 1
        album = start < player.queue.count ? Array(player.queue[start...]) : []
        if let p = picked, !(playNext + album + userQ).contains(where: { $0.id == p }) {
            picked = nil
        }
    }

    private func jump(_ section: QSection, index i: Int) {
        switch section {
        case .playNext: player.jumpToPlayNext(at: i)
        case .album:    player.jumpToQueueTrack(at: player.currentIndex + 1 + i)
        case .user:     player.jumpToUserQueue(at: i)
        }
    }

    private func move(_ section: QSection, id: String, up: Bool) {
        func reorder(_ arr: inout [Song], _ apply: (IndexSet, Int) -> Void) {
            guard let i = arr.firstIndex(where: { $0.id == id }) else { return }
            guard (up && i > 0) || (!up && i < arr.count - 1) else { return }
            let to = up ? i - 1 : i + 2   // SwiftUI move-Offset-Semantik
            arr.move(fromOffsets: IndexSet(integer: i), toOffset: to)
            apply(IndexSet(integer: i), to)
        }
        switch section {
        case .playNext: reorder(&playNext) { player.moveInPlayNextQueue(from: $0, to: $1) }
        case .album:    reorder(&album)    { player.moveInQueue(from: $0, to: $1) }
        case .user:     reorder(&userQ)    { player.moveInUserQueue(from: $0, to: $1) }
        }
    }

    private func delete(_ section: QSection, index i: Int) {
        switch section {
        case .playNext: player.removeFromPlayNextQueue(at: i)
        case .album:    player.removeFromPlayQueue(at: player.currentIndex + 1 + i)
        case .user:     player.removeFromUserQueue(at: i)
        }
        sync()
    }
}

/// Eine Queue-Zeile mit Edit-Verhalten:
/// - Normal: Select springt zum Song.
/// - Edit: Select nimmt den Song auf/legt ihn ab; im aufgenommenen Zustand bewegt Hoch/Runter
///   ihn (via onMoveCommand, nur dann aktiv — sonst normale Navigation). Rechts daneben ein
///   Lösch-Icon, das man durch einmal Rechts-Drücken erreicht.
private struct QueueRow: View {
    let song: Song
    let isEditing: Bool
    let isPicked: Bool
    let accent: Color
    let onSelect: () -> Void
    let onMove: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onSelect) {
                HStack(spacing: 16) {
                    CoverArtView(url: song.coverURL(200), size: 56, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).lineLimit(1)
                        if let artist = song.artist {
                            Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if isPicked {
                        Image(systemName: "arrow.up.arrow.down.circle.fill")
                            .foregroundStyle(accent)
                    } else if let d = song.duration {
                        Text(formatDuration(d)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .buttonStyle(.card)
            // Nur im aufgenommenen Zustand Hoch/Runter abfangen — sonst nil = normale Navigation.
            .onMoveCommand(perform: isPicked ? { direction in
                switch direction {
                case .up:   onMove(true)
                case .down: onMove(false)
                default:    break
                }
            } : nil)

            if isEditing {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 36)
    }
}
