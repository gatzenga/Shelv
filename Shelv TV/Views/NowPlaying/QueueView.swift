import SwiftUI

struct QueueView: View {
    @ObservedObject var player = AudioPlayerService.shared

    private var upcomingAlbum: [Song] {
        let start = player.currentIndex + 1
        return start < player.queue.count ? Array(player.queue[start...]) : []
    }

    private var isEmpty: Bool {
        player.playNextQueue.isEmpty && upcomingAlbum.isEmpty && player.userQueue.isEmpty
    }

    var body: some View {
        if isEmpty {
            ContentUnavailableView(String(localized: "queue_empty"), systemImage: "music.note.list")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !player.playNextQueue.isEmpty {
                        sectionHeader(String(localized: "play_next"))
                        ForEach(Array(player.playNextQueue.enumerated()), id: \.element.id) { i, song in
                            DetailSongRow(song: song, number: i, showArtwork: true,
                                          queueActions: actions(.playNext, i, player.playNextQueue.count)) {
                                player.jumpToPlayNext(at: i)
                            }
                        }
                    }
                    if !upcomingAlbum.isEmpty {
                        sectionHeader(String(localized: "up_next"))
                        ForEach(Array(upcomingAlbum.enumerated()), id: \.element.id) { i, song in
                            DetailSongRow(song: song, number: i, showArtwork: true,
                                          queueActions: actions(.album, i, upcomingAlbum.count)) {
                                player.jumpToQueueTrack(at: player.currentIndex + 1 + i)
                            }
                        }
                    }
                    if !player.userQueue.isEmpty {
                        sectionHeader(String(localized: "your_queue"))
                        ForEach(Array(player.userQueue.enumerated()), id: \.element.id) { i, song in
                            DetailSongRow(song: song, number: i, showArtwork: true,
                                          queueActions: actions(.user, i, player.userQueue.count)) {
                                player.jumpToUserQueue(at: i)
                            }
                        }
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .edgeFadeMask(fade: 0.04)
        }
    }

    private enum QSection { case playNext, album, user }

    /// Queue-Aktionen fürs Kontextmenü (Select gedrückt halten). Nur sinnvolle Einträge.
    private func actions(_ section: QSection, _ i: Int, _ count: Int) -> QueueRowActions {
        QueueRowActions(
            moveUp:   i > 0 ? { move(section, i, up: true) } : nil,
            moveDown: i < count - 1 ? { move(section, i, up: false) } : nil,
            moveToTop: i > 0 ? { moveTo(section, i, 0) } : nil,
            remove:   { remove(section, i) }
        )
    }

    private func move(_ section: QSection, _ i: Int, up: Bool) {
        moveTo(section, i, up ? i - 1 : i + 2)   // SwiftUI move-Offset-Semantik
    }

    private func moveTo(_ section: QSection, _ i: Int, _ to: Int) {
        let from = IndexSet(integer: i)
        switch section {
        case .playNext: player.moveInPlayNextQueue(from: from, to: to)
        case .album:    player.moveInQueue(from: from, to: to)
        case .user:     player.moveInUserQueue(from: from, to: to)
        }
    }

    private func remove(_ section: QSection, _ i: Int) {
        switch section {
        case .playNext: player.removeFromPlayNextQueue(at: i)
        case .album:    player.removeFromPlayQueue(at: player.currentIndex + 1 + i)
        case .user:     player.removeFromUserQueue(at: i)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3).bold()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 36)
            .padding(.top, 20)
            .padding(.bottom, 4)
    }
}
