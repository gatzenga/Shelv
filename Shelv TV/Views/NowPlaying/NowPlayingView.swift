import SwiftUI

private enum SidePanel { case lyrics, queue }

struct NowPlayingView: View {
    @ObservedObject var player = AudioPlayerService.shared

    @State private var displayTime: Double = 0
    @State private var displayDuration: Double = 0
    @State private var panel: SidePanel?

    var body: some View {
        Group {
            if player.currentSong != nil {
                HStack(spacing: 0) {
                    playerColumn
                        .frame(maxWidth: .infinity)

                    if let panel {
                        Divider()
                        sidePanel(panel)
                            .frame(width: 720)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: panel)
                .onReceive(player.timePublisher) { t in
                    displayTime = t.time
                    displayDuration = t.duration
                }
            } else {
                ContentUnavailableView(
                    String(localized: "nothing_playing"),
                    systemImage: "play.slash"
                )
            }
        }
    }

    // MARK: - Player (links)

    private var playerColumn: some View {
        VStack(spacing: 26) {
            CoverArtView(url: player.currentSong?.coverURL(700), size: panel == nil ? 380 : 300, cornerRadius: 16)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                .animation(.easeInOut(duration: 0.25), value: panel)

            VStack(spacing: 6) {
                Text(player.displayTitle).font(.title2).bold().lineLimit(1)
                if let artist = player.currentSong?.artist {
                    Text(artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                }
                if let album = player.currentSong?.album {
                    Text(album).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                }
            }

            VStack(spacing: 6) {
                ProgressView(value: displayDuration > 0 ? min(displayTime / displayDuration, 1) : 0)
                    .frame(maxWidth: 620)
                HStack {
                    Text(formatDuration(Int(displayTime))).monospacedDigit()
                    Spacer()
                    Text(formatDuration(Int(displayDuration))).monospacedDigit()
                }
                .frame(maxWidth: 620)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 30) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.body)
                }
                Button { player.next(triggeredByUser: true) } label: { Image(systemName: "forward.fill") }
                Button { player.repeatMode = player.repeatMode.toggled } label: {
                    Image(systemName: player.repeatMode.systemImage)
                        .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                }
            }
            .font(.callout)

            HStack(spacing: 30) {
                Button { toggle(.lyrics) } label: {
                    Label(String(localized: "lyrics"), systemImage: "text.quote")
                }
                Button { toggle(.queue) } label: {
                    Label(String(localized: "queue"), systemImage: "list.bullet")
                }
            }
        }
        .padding(50)
    }

    private func toggle(_ p: SidePanel) {
        panel = (panel == p) ? nil : p
    }

    // MARK: - Seitenpanel (rechts)

    @ViewBuilder
    private func sidePanel(_ p: SidePanel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(p == .lyrics ? String(localized: "lyrics") : String(localized: "queue"))
                .font(.title2).bold()
                .padding([.top, .horizontal], 40)
            switch p {
            case .lyrics: LyricsView()
            case .queue:  QueueView()
            }
        }
    }
}
