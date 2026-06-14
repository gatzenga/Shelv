import SwiftUI

struct QueueView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColor = "violet"
    @AppStorage("infinityModeEnabled") private var infinityMode = false
    private var accent: Color { AppTheme.color(for: themeColor) }

    /// Hält den Fokus nach dem Abspielen eines Titels (der dann aus der Liste verschwindet)
    /// auf der nächsten Zeile — sonst verliert tvOS den Fokus komplett.
    @FocusState private var focusedID: String?

    private var upcomingAlbum: [Song] {
        let start = player.currentIndex + 1
        return start < player.queue.count ? Array(player.queue[start...]) : []
    }

    private var isEmpty: Bool {
        player.playNextQueue.isEmpty && upcomingAlbum.isEmpty && player.userQueue.isEmpty
    }

    private var firstUpcomingID: String? {
        player.playNextQueue.first?.id ?? upcomingAlbum.first?.id ?? player.userQueue.first?.id
    }

    /// Nach einem Abspiel-Tap den Fokus auf den neuen obersten Titel setzen (nächster Runloop,
    /// damit die Liste vorher neu rendert).
    private func keepFocusAfterPlay() {
        Task { @MainActor in focusedID = firstUpcomingID }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    Image(systemName: "infinity")
                        .foregroundStyle(infinityMode ? accent : .primary)
                    Text(String(localized: "infinity_mode"))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: infinityMode ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(infinityMode ? accent : .secondary)
                }
                .rowButton {
                    infinityMode.toggle()
                    if infinityMode { player.topUpInfinityIfNeeded() }
                }
                .padding(.bottom, 8)

                if isEmpty {
                    Text(String(localized: "queue_empty"))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 36)
                        .padding(.top, 20)
                } else {
                    if !player.playNextQueue.isEmpty {
                        sectionHeader(String(localized: "play_next"))
                        ForEach(Array(player.playNextQueue.enumerated()), id: \.element.id) { i, song in
                            row(song) { player.jumpToPlayNext(at: i) }
                        }
                    }
                    if !upcomingAlbum.isEmpty {
                        sectionHeader(String(localized: "up_next"))
                        ForEach(Array(upcomingAlbum.enumerated()), id: \.element.id) { i, song in
                            row(song) { player.jumpToQueueTrack(at: player.currentIndex + 1 + i) }
                        }
                    }
                    if !player.userQueue.isEmpty {
                        sectionHeader(String(localized: "your_queue"))
                        ForEach(Array(player.userQueue.enumerated()), id: \.element.id) { i, song in
                            row(song) { player.jumpToUserQueue(at: i) }
                        }
                    }
                }
            }
            .padding(.vertical, 90)
        }
        .scrollIndicators(.hidden)
        .edgeFadeMask()
    }

    private func row(_ song: Song, _ play: @escaping () -> Void) -> some View {
        DetailSongRow(song: song, number: 0, showArtwork: true, showContextMenu: false) {
            play()
            keepFocusAfterPlay()
        }
        .focused($focusedID, equals: song.id)
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
