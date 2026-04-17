import SwiftUI

/// Zeigt einen animierten Akzent-Rahmen und Equalizer-Icon auf dem Cover,
/// wenn der Song gerade abgespielt wird.
struct NowPlayingOverlay: View {
    let songId: String
    let size: CGFloat
    let cornerRadius: CGFloat
    let accentColor: Color

    @ObservedObject private var player = AudioPlayerService.shared

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
