import SwiftUI

struct PlayerBarView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @ObservedObject private var radioStore = RadioStationStore.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("radioSortDirection") private var radioSortDirectionRaw = SortDirection.ascending.rawValue
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var isRegular: Bool { hSizeClass == .regular }
    private var radioDisplayItems: [RadioStationDisplayItem] {
        let direction = SortDirection(rawValue: radioSortDirectionRaw) ?? .ascending
        return direction == .descending ? Array(radioStore.items.reversed()) : radioStore.items
    }

    // iPad bekommt eine kompakte, aber merklich größere Variante
    private var coverSize: CGFloat { isRegular ? 56 : 40 }
    private var coverCorner: CGFloat { isRegular ? 10 : 8 }
    private var vPad: CGFloat { isRegular ? 10 : 8 }
    private var hPad: CGFloat { isRegular ? 18 : 16 }
    private var hStackSpacing: CGFloat { isRegular ? 14 : 12 }
    private var skipSize: CGFloat { isRegular ? 36 : 30 }
    private var playSize: CGFloat { isRegular ? 44 : 36 }
    private var titleFont: Font { isRegular ? .body : .subheadline }
    private var subtitleFont: Font { isRegular ? .footnote : .caption }
    private var skipIconFont: Font { isRegular ? .body : .callout }
    private var playIconFont: Font { isRegular ? .title3 : .body }

    var body: some View {
        HStack(spacing: hStackSpacing) {
            if let station = player.currentRadioStation {
                RadioStationArtworkView(
                    item: station,
                    size: coverSize,
                    metadata: player.currentRadioMetadata,
                    reloadToken: player.artworkReloadToken
                )
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            } else {
                AlbumArtView(coverArtId: player.currentSong?.coverArt, size: 100, cornerRadius: coverCorner)
                    .frame(width: coverSize, height: coverSize)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                if player.isRadioPlayback && player.isRadioConnecting {
                    Text(player.radioStatusText)
                        .font(titleFont).bold()
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if player.showBufferingIndicator {
                    Text(String(localized: "loading"))
                        .font(titleFont).bold()
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text(player.displayTitle)
                        .font(titleFont).bold()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(player.displaySubtitleLine)
                    .font(subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if player.isRadioPlayback {
                Button {
                    player.playPreviousRadioStation(in: radioDisplayItems)
                } label: {
                    Image(systemName: "backward.fill")
                        .font(skipIconFont)
                        .foregroundStyle(radioDisplayItems.count > 1 ? Color.primary : Color.secondary)
                        .frame(width: skipSize, height: skipSize)
                }
                .buttonStyle(.plain)
                .disabled(radioDisplayItems.count <= 1)
            } else {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(skipIconFont)
                        .foregroundStyle(.primary)
                        .frame(width: skipSize, height: skipSize)
                }
                .buttonStyle(.plain)
            }

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(playIconFont)
                    .foregroundStyle(.white)
                    .frame(width: playSize, height: playSize)
                    .background(accentColor)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            if player.isRadioPlayback {
                Button {
                    player.playNextRadioStation(in: radioDisplayItems)
                } label: {
                    Image(systemName: "forward.fill")
                        .font(skipIconFont)
                        .foregroundStyle(radioDisplayItems.count > 1 ? Color.primary : Color.secondary)
                        .frame(width: skipSize, height: skipSize)
                }
                .buttonStyle(.plain)
                .disabled(radioDisplayItems.count <= 1)
            } else {
                Button {
                    player.next(triggeredByUser: true)
                } label: {
                    Image(systemName: "forward.fill")
                        .font(skipIconFont)
                        .foregroundStyle(player.hasNextTrack ? Color.primary : Color.secondary)
                        .frame(width: skipSize, height: skipSize)
                }
                .buttonStyle(.plain)
                .disabled(!player.hasNextTrack)
            }
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .contentShape(Rectangle())
        .modifier(LiquidGlassBar())
    }
}

private struct LiquidGlassBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: Capsule(style: .continuous)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}
