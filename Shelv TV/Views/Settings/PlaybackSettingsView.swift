import SwiftUI

struct PlaybackSettingsView: View {
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @AppStorage("replayGainEnabled") private var replayGainEnabled = false
    @AppStorage("replayGainMode") private var replayGainMode = "track"
    @AppStorage("recapThreshold") private var recapThreshold = 30

    var body: some View {
        Form {
            Section(String(localized: "gapless")) {
                Toggle(String(localized: "gapless"), isOn: $gaplessEnabled)
            }

            Section(String(localized: "replay_gain")) {
                Toggle(String(localized: "replay_gain"), isOn: $replayGainEnabled)
                if replayGainEnabled {
                    Picker(String(localized: "replay_gain_mode"), selection: $replayGainMode) {
                        Text(String(localized: "track_gain")).tag("track")
                        Text(String(localized: "album_gain")).tag("album")
                    }
                }
            }

            Section(String(localized: "scrobble")) {
                Picker(String(localized: "count_from"), selection: $recapThreshold) {
                    ForEach([10, 20, 30, 40, 50], id: \.self) { pct in
                        Text("\(pct)%").tag(pct)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "playback"))
    }
}
