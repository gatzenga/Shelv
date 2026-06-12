import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player = AudioPlayerService.shared

    @State private var displayTime: Double = 0
    @State private var displayDuration: Double = 0
    @State private var showLyrics = false

    var body: some View {
        NavigationStack {
            if let song = player.currentSong {
                VStack(spacing: 30) {
                    CoverArtView(url: song.coverURL(700), size: 420, cornerRadius: 16)
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)

                    VStack(spacing: 6) {
                        Text(player.displayTitle).font(.title).bold().lineLimit(1)
                        if let artist = song.artist {
                            Text(artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let album = song.album {
                            Text(album).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }

                    VStack(spacing: 6) {
                        ProgressView(value: displayDuration > 0 ? min(displayTime / displayDuration, 1) : 0)
                            .frame(maxWidth: 760)
                        HStack {
                            Text(formatDuration(Int(displayTime))).monospacedDigit()
                            Spacer()
                            Text(formatDuration(Int(displayDuration))).monospacedDigit()
                        }
                        .frame(maxWidth: 760)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 36) {
                        Button { player.toggleShuffle() } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(player.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        }
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                        Button { player.next(triggeredByUser: true) } label: { Image(systemName: "forward.fill") }
                        Button { player.repeatMode = player.repeatMode.toggled } label: {
                            Image(systemName: player.repeatMode.systemImage)
                                .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                        }
                    }
                    .font(.title3)

                    Button { showLyrics = true } label: {
                        Label(String(localized: "lyrics"), systemImage: "text.quote")
                    }
                }
                .padding(50)
                .onReceive(player.timePublisher) { t in
                    displayTime = t.time
                    displayDuration = t.duration
                }
                .fullScreenCover(isPresented: $showLyrics) {
                    LyricsView()
                }
            } else {
                ContentUnavailableView(
                    String(localized: "nothing_playing"),
                    systemImage: "play.slash"
                )
            }
        }
    }
}
