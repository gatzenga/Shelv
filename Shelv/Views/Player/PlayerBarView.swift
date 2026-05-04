import SwiftUI

struct PlayerBarView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: player.currentSong?.coverArt, size: 100, cornerRadius: 10)
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                if player.showBufferingIndicator {
                    Text(tr("Loading...", "Lädt..."))
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
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body)
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
                    .foregroundStyle(player.hasNextTrack ? Color.primary : Color.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasNextTrack)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .modifier(LiquidGlassBar())
    }
}

private struct LiquidGlassBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 32, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}
