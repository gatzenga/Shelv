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
        Group {
            if isEmpty {
                ContentUnavailableView(String(localized: "queue_empty"), systemImage: "music.note.list")
            } else {
                List {
                    if !player.playNextQueue.isEmpty {
                        Section(String(localized: "play_next")) {
                            ForEach(Array(player.playNextQueue.enumerated()), id: \.element.id) { i, song in
                                SongRow(song: song, index: i) { player.jumpToPlayNext(at: i) }
                            }
                        }
                    }
                    if !upcomingAlbum.isEmpty {
                        // Kein eigener Header — der Panel-Titel sagt bereits "Warteschlange".
                        Section {
                            ForEach(Array(upcomingAlbum.enumerated()), id: \.element.id) { i, song in
                                SongRow(song: song, index: i) {
                                    player.jumpToQueueTrack(at: player.currentIndex + 1 + i)
                                }
                            }
                        }
                    }
                    if !player.userQueue.isEmpty {
                        Section(String(localized: "added_to_queue")) {
                            ForEach(Array(player.userQueue.enumerated()), id: \.element.id) { i, song in
                                SongRow(song: song, index: i) { player.jumpToUserQueue(at: i) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
