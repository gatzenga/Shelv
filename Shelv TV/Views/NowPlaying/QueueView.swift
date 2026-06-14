import SwiftUI

struct QueueView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColor = "violet"
    @AppStorage("infinityModeEnabled") private var infinityMode = false
    private var accent: Color { AppTheme.color(for: themeColor) }

    private var upcomingAlbum: [Song] {
        let start = player.currentIndex + 1
        return start < player.queue.count ? Array(player.queue[start...]) : []
    }

    private var isEmpty: Bool {
        player.playNextQueue.isEmpty && upcomingAlbum.isEmpty && player.userQueue.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $infinityMode) {
                    Label(String(localized: "infinity_mode"), systemImage: "infinity")
                }
                .tint(accent)
                .padding(.horizontal, 36)
                .padding(.bottom, 8)
                .onChange(of: infinityMode) { _, on in
                    if on { player.topUpInfinityIfNeeded() }
                }

                if isEmpty {
                    Text(String(localized: "queue_empty"))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 36)
                        .padding(.top, 20)
                } else {
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
            }
            .padding(.vertical, 90)
        }
        .scrollIndicators(.hidden)
        .edgeFadeMask()
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
