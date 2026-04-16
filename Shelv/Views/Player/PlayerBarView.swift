import SwiftUI

struct PlayerBarView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        HStack(spacing: 14) {
            AlbumArtView(coverArtId: player.currentSong?.coverArt, size: 100, cornerRadius: 10)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                .overlay(alignment: .bottomTrailing) {
                    if player.isBuffering || player.isPlaying || !player.isNetworkAvailable {
                        Circle()
                            .fill(!player.isNetworkAvailable ? Color.red : player.isBuffering ? Color.orange : Color.green)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                if player.isBuffering {
                    Text(tr("Connecting...", "Verbinde..."))
                        .font(.subheadline).bold()
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text(player.displayTitle)
                        .font(.subheadline).bold()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(player.currentSong?.artist ?? player.currentSong?.album ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.callout)
                    .foregroundStyle(accentColor)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(accentColor)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                player.next(triggeredByUser: true)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.callout)
                    .foregroundStyle(player.hasNextTrack ? accentColor : Color.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasNextTrack)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(UIColor.systemBackground)
                .opacity(0.85)
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 15, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}
