import SwiftUI

/// Isolierter Spacer, der nur `currentSong` beobachtet — verhindert,
/// dass die gesamte umgebende View bei jedem currentTime-Update neu rendert.
struct PlayerBottomSpacer: View {
    var activeHeight: CGFloat = 90
    var inactiveHeight: CGFloat = 16

    @ObservedObject private var player = AudioPlayerService.shared

    var body: some View {
        Color.clear
            .frame(height: player.currentSong != nil ? activeHeight : inactiveHeight)
    }
}
