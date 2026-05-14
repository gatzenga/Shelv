import SwiftUI

struct PlaybackSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @AppStorage("transcodingEnabled") private var transcodingEnabled = false
    @AppStorage("replayGainEnabled") private var replayGainEnabled = false
    @AppStorage("replayGainMode") private var replayGainMode = "track"

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section(String(localized: "transcoding")) {
                Toggle(isOn: $transcodingEnabled) {
                    Label { Text(String(localized: "transcoding")) } icon: {
                        Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)
                if transcodingEnabled {
                    NavigationLink(destination: TranscodingSettingsView()) {
                        Label { Text(String(localized: "settings")) } icon: {
                            Image(systemName: "slider.horizontal.3").foregroundStyle(accentColor)
                        }
                    }
                }
            }

            Section(String(localized: "gapless")) {
                Toggle(isOn: $gaplessEnabled) {
                    Label { Text(String(localized: "gapless")) } icon: {
                        Image(systemName: "waveform.path").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)
                if gaplessEnabled {
                    Text(String(localized: "precache_original_file_recommendedntranscoded_stre"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "replay_gain")) {
                Toggle(isOn: $replayGainEnabled) {
                    Label { Text(String(localized: "replay_gain")) } icon: {
                        Image(systemName: "dial.medium").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)
                if replayGainEnabled {
                    Picker(selection: $replayGainMode) {
                        Text(String(localized: "track_gain")).tag("track")
                        Text(String(localized: "album_gain")).tag("album")
                    } label: {
                        Label { Text(String(localized: "replay_gain_mode")) } icon: {
                            Image(systemName: "switch.2").foregroundStyle(accentColor)
                        }
                    }
                }
            }

            PlayerBottomSpacer()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .navigationTitle(String(localized: "playback"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
