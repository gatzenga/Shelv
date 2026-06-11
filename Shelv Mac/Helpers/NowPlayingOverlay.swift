import SwiftUI

struct NowPlayingOverlay: View {
    let songId: String
    let size: CGFloat
    let cornerRadius: CGFloat

    @ObservedObject private var player = AudioPlayerService.shared
    @Environment(\.themeColor) private var themeColor

    private var isActive: Bool { player.currentSong?.id == songId }

    var body: some View {
        if isActive {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: size, height: size)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: player.isPlaying)
            }
        }
    }
}
