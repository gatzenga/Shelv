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
                            DetailSongRow(song: song, number: i, showArtwork: true) {
                                player.jumpToPlayNext(at: i)
                            }
                        }
                    }
                    if !upcomingAlbum.isEmpty {
                        sectionHeader(String(localized: "up_next"))
                        ForEach(Array(upcomingAlbum.enumerated()), id: \.element.id) { i, song in
                            DetailSongRow(song: song, number: i, showArtwork: true) {
                                player.jumpToQueueTrack(at: player.currentIndex + 1 + i)
                            }
                        }
                    }
                    if !player.userQueue.isEmpty {
                        sectionHeader(String(localized: "your_queue"))
                        ForEach(Array(player.userQueue.enumerated()), id: \.element.id) { i, song in
                            DetailSongRow(song: song, number: i, showArtwork: true) {
                                player.jumpToUserQueue(at: i)
                            }
                        }
                    }
                }
                .padding(.vertical, 30)
            }
            .scrollIndicators(.hidden)
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
