import SwiftUI

struct PlaybackSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @AppStorage("transcodingEnabled") private var transcodingEnabled = false
    @AppStorage("replayGainEnabled") private var replayGainEnabled = false
    @AppStorage("replayGainMode") private var replayGainMode = "track"
    @AppStorage("recapThreshold") private var recapThreshold = 30
    @AppStorage("queueSyncMode") private var queueSyncMode = "off"

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

            Section(String(localized: "scrobble")) {
                Picker(selection: $recapThreshold) {
                    ForEach([10, 20, 30, 40, 50], id: \.self) { pct in
                        Text("\(pct)%").tag(pct)
                    }
                } label: {
                    Label { Text(String(localized: "count_from")) } icon: {
                        Image(systemName: "checkmark.seal").foregroundStyle(accentColor)
                    }
                }
            }

            Section(String(localized: "queue_sync")) {
                Picker(selection: $queueSyncMode) {
                    Text(String(localized: "queue_sync_off")).tag("off")
                    Text(String(localized: "queue_sync_subsonic")).tag("subsonic")
                    Text(String(localized: "queue_sync_icloud")).tag("icloud")
                } label: {
                    Label { Text(String(localized: "queue_sync")) } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accentColor)
                    }
                }
            }

            Section(String(localized: "about")) {
                Text(String(localized: "queue_sync_about_icloud"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "queue_sync_about_subsonic"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "logs")) {
                NavigationLink(destination: QueueSyncLogView()) {
                    Label { Text(String(localized: "queue_sync_log")) } icon: {
                        Image(systemName: "doc.text").foregroundStyle(accentColor)
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
