import SwiftUI

struct PlaybackSettingsWindow: View {
    var body: some View {
        TabView {
            GaplessPanel()
                .tabItem {
                    Image(systemName: "music.note.list")
                    Text(String(localized: "gapless"))
                }
            TranscodingPanel()
                .tabItem {
                    Image(systemName: "waveform.badge.magnifyingglass")
                    Text(String(localized: "transcoding"))
                }
            ReplayGainPanel()
                .tabItem {
                    Image(systemName: "dial.medium")
                    Text(String(localized: "replay_gain"))
                }
            ScrobblePanel()
                .tabItem {
                    Image(systemName: "checkmark.seal")
                    Text(String(localized: "scrobble"))
                }
            LyricsSettingsPanel()
                .tabItem {
                    Image(systemName: "text.quote")
                    Text(String(localized: "lyrics"))
                }
        }
        .frame(width: 820, height: 660)
        .transaction { $0.animation = nil }
    }
}
