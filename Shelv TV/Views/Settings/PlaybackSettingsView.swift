import SwiftUI

struct PlaybackSettingsView: View {
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @AppStorage("replayGainEnabled") private var replayGainEnabled = false
    @AppStorage("replayGainMode") private var replayGainMode = "track"
    @AppStorage("recapThreshold") private var recapThreshold = 30
    // Apple TV kennt kein Mobilfunk → ein einziges (WLAN/Ethernet-)Profil reicht.
    @AppStorage("transcodingEnabled") private var transcodingEnabled = false
    @AppStorage("transcodingWifiCodec") private var streamCodec = "raw"
    @AppStorage("transcodingWifiBitrate") private var streamBitrate = 256
    @AppStorage("queueSyncMode") private var queueSyncMode = "off"

    var body: some View {
        Form {
            Text(String(localized: "playback"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)
            Section(String(localized: "gapless")) {
                Toggle(String(localized: "gapless"), isOn: $gaplessEnabled)
            }

            Section(String(localized: "transcoding")) {
                Toggle(String(localized: "transcoding"), isOn: $transcodingEnabled)
                if transcodingEnabled {
                    Picker(String(localized: "format"), selection: $streamCodec) {
                        ForEach(TranscodingCodec.streamingOptions) { codec in
                            Text(codec.label).tag(codec.rawValue)
                        }
                    }
                    if streamCodec != "raw" {
                        Picker(String(localized: "bitrate"), selection: $streamBitrate) {
                            ForEach(TranscodingBitrate.allCases) { rate in
                                Text(rate.label).tag(rate.rawValue)
                            }
                        }
                    }
                }
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

            Section(String(localized: "queue_sync")) {
                Picker(String(localized: "queue_sync"), selection: $queueSyncMode) {
                    Text(String(localized: "queue_sync_off")).tag("off")
                    Text(String(localized: "queue_sync_subsonic")).tag("subsonic")
                    Text(String(localized: "queue_sync_icloud")).tag("icloud")
                }
                NavigationLink(String(localized: "about")) {
                    QueueSyncAboutView()
                }
                NavigationLink(String(localized: "queue_sync_log")) {
                    QueueSyncLogView()
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Erklärtext zum Queue-Sync (tvOS: als Unterseite statt Inline-Text).
private struct QueueSyncAboutView: View {
    var body: some View {
        ScrollView {
            // tvOS: reiner Text ist nicht fokussierbar → ohne .focusable() bricht die
            // Navigation (Menü-Taste schließt die App statt zurückzugehen) und es scrollt nicht.
            VStack(alignment: .leading, spacing: 24) {
                Text(String(localized: "queue_sync_about_icloud"))
                Text(String(localized: "queue_sync_about_subsonic"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(60)
            .focusable()
        }
        .navigationTitle(String(localized: "queue_sync"))
    }
}

/// Live Queue-Sync-Log — beobachtet den QueueSyncService, neue Zeilen erscheinen sofort.
private struct QueueSyncLogView: View {
    @ObservedObject private var queueSync = QueueSyncService.shared

    var body: some View {
        LogListView(title: String(localized: "queue_sync_log"), entries: queueSync.logEntries)
    }
}
