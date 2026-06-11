import SwiftUI

struct ReplayGainPanel: View {
    @AppStorage("replayGainEnabled") private var replayGainEnabled = false
    @AppStorage("replayGainMode") private var replayGainMode = "track"
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $replayGainEnabled) {
                    Label(String(localized: "replay_gain"), systemImage: "dial.medium")
                }
                .tint(themeColor)
                if replayGainEnabled {
                    Picker(String(localized: "replay_gain_mode"), selection: $replayGainMode) {
                        Text(String(localized: "track_gain")).tag("track")
                        Text(String(localized: "album_gain")).tag("album")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
