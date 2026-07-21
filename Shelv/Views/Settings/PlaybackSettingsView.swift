import SwiftUI

struct PlaybackSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @AppStorage("transcodingEnabled") private var transcodingEnabled = false
    @AppStorage("replayGainEnabled") private var replayGainEnabled = false
    @AppStorage("replayGainMode") private var replayGainMode = "track"
    @AppStorage("recapThreshold") private var recapThreshold = 30
    @AppStorage("queueSyncMode") private var queueSyncMode = "off"
    @AppStorage("infinityMixAheadCount") private var infinityMixAheadCount = 1
    @AppStorage(AudioPlayerStateKey.savePlayerState) private var savePlayerState = true
    @State private var showAboutQueueSync = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private let infinityMixAheadOptions = Array(1...10)

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
                .onChange(of: queueSyncMode) { _, _ in
                    QueueSyncService.shared.handleModeChange()
                }
                Button {
                    showAboutQueueSync = true
                } label: {
                    Label {
                        Text(String(localized: "about")).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(accentColor)
                    }
                }
                .sheet(isPresented: $showAboutQueueSync) {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(String(localized: "queue_sync_about_icloud"))
                                Text(String(localized: "queue_sync_about_subsonic"))
                            }
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .navigationTitle(String(localized: "queue_sync"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "done")) { showAboutQueueSync = false }
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
                NavigationLink(destination: QueueSyncLogView()) {
                    Label { Text(String(localized: "logs")) } icon: {
                        Image(systemName: "doc.text").foregroundStyle(accentColor)
                    }
                }
            }

            Section(String(localized: "infinity_mix")) {
                Picker(selection: $infinityMixAheadCount) {
                    ForEach(infinityMixAheadOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                } label: {
                    Label { Text(String(localized: "infinity_mix_ahead_count")) } icon: {
                        Image(systemName: "infinity").foregroundStyle(accentColor)
                    }
                }
                .onChange(of: infinityMixAheadCount) { _, _ in
                    AudioPlayerService.shared.refreshInfinityMixWindow()
                }
            }

            Section(String(localized: "player_state")) {
                Toggle(isOn: $savePlayerState) {
                    Label { Text(String(localized: "save_player_state")) } icon: {
                        Image(systemName: "play.circle").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)
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
