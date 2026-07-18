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
    @AppStorage("infinityMixAheadCount") private var infinityMixAheadCount = 1
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true
    @AppStorage("includeNavidromeLyrics") private var includeNavidromeLyrics = true
    @AppStorage("useCustomLrcLibServer") private var useCustomLrcLibServer = false
    @AppStorage("customLrcLibBaseURL") private var customLrcLibBaseURL = ""
    @AppStorage(LrcLibEndpoint.onlineFallbackEnabledKey) private var lrcLibOnlineFallbackEnabled = true

    @State private var showLrcLibServerEditor = false
    @State private var draftLrcLibBaseURL = ""

    private var codecOptions: [TVSettingsChoiceOption<String>] {
        TranscodingCodec.streamingOptions.map { codec in
            TVSettingsChoiceOption(value: codec.rawValue, title: codec.label)
        }
    }
    private var bitrateOptions: [TVSettingsChoiceOption<Int>] {
        TranscodingBitrate.allCases.map { rate in
            TVSettingsChoiceOption(value: rate.rawValue, title: rate.label)
        }
    }
    private var replayGainOptions: [TVSettingsChoiceOption<String>] {
        [
            TVSettingsChoiceOption(value: "track", title: String(localized: "track_gain")),
            TVSettingsChoiceOption(value: "album", title: String(localized: "album_gain")),
        ]
    }
    private var recapThresholdOptions: [TVSettingsChoiceOption<Int>] {
        [10, 20, 30, 40, 50].map { pct in
            TVSettingsChoiceOption(value: pct, title: "\(pct)%")
        }
    }
    private var queueSyncOptions: [TVSettingsChoiceOption<String>] {
        [
            TVSettingsChoiceOption(value: "off", title: String(localized: "queue_sync_off")),
            TVSettingsChoiceOption(value: "subsonic", title: String(localized: "queue_sync_subsonic")),
            TVSettingsChoiceOption(value: "icloud", title: String(localized: "queue_sync_icloud")),
        ]
    }
    private var infinityMixAheadOptions: [TVSettingsChoiceOption<Int>] {
        (1...10).map { count in
            TVSettingsChoiceOption(value: count, title: "\(count)")
        }
    }

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
                    TVSettingsChoiceRow(
                        title: String(localized: "format"),
                        selection: $streamCodec,
                        options: codecOptions
                    )
                    if streamCodec != "raw" {
                        TVSettingsChoiceRow(
                            title: String(localized: "bitrate"),
                            selection: $streamBitrate,
                            options: bitrateOptions
                        )
                    }
                }
            }

            Section(String(localized: "replay_gain")) {
                Toggle(String(localized: "replay_gain"), isOn: $replayGainEnabled)
                if replayGainEnabled {
                    TVSettingsChoiceRow(
                        title: String(localized: "replay_gain_mode"),
                        selection: $replayGainMode,
                        options: replayGainOptions
                    )
                }
            }

            Section(String(localized: "scrobble")) {
                TVSettingsChoiceRow(
                    title: String(localized: "count_from"),
                    selection: $recapThreshold,
                    options: recapThresholdOptions
                )
            }

            Section(String(localized: "lyrics")) {
                Toggle(String(localized: "autofetch_on_playback"), isOn: $autoFetchLyrics)
                Toggle(String(localized: "include_navidrome_lyrics"), isOn: $includeNavidromeLyrics)
                Toggle(String(localized: "use_custom_lrclib_server"), isOn: $useCustomLrcLibServer)
                    .onChange(of: useCustomLrcLibServer) { _, _ in
                        Task { await CloudKitSyncService.shared.recordLyricsServerSettingsChange() }
                    }
                if useCustomLrcLibServer {
                    Button {
                        draftLrcLibBaseURL = customLrcLibBaseURL
                        showLrcLibServerEditor = true
                    } label: {
                        HStack {
                            Text(String(localized: "lrclib_server_url"))
                            Spacer()
                            Text(customLrcLibBaseURL.isEmpty ? LrcLibEndpoint.defaultBaseURL : customLrcLibBaseURL)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Toggle(String(localized: "lrclib_online_fallback"), isOn: $lrcLibOnlineFallbackEnabled)
                        .onChange(of: lrcLibOnlineFallbackEnabled) { _, _ in
                            Task { await CloudKitSyncService.shared.recordLyricsServerSettingsChange() }
                        }
                }
            }

            Section(String(localized: "queue_sync")) {
                TVSettingsChoiceRow(
                    title: String(localized: "queue_sync"),
                    selection: $queueSyncMode,
                    options: queueSyncOptions
                ) { _ in
                    QueueSyncService.shared.handleModeChange()
                }
                NavigationLink(String(localized: "about")) {
                    QueueSyncAboutView()
                }
                NavigationLink(String(localized: "queue_sync_log")) {
                    QueueSyncLogView()
                }
            }

            Section(String(localized: "infinity_mix")) {
                TVSettingsChoiceRow(
                    title: String(localized: "infinity_mix_ahead_count"),
                    selection: $infinityMixAheadCount,
                    options: infinityMixAheadOptions
                ) { _ in
                    AudioPlayerService.shared.refreshInfinityMixWindow()
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .alert(String(localized: "lrclib_server_url"), isPresented: $showLrcLibServerEditor) {
            TextField(String(localized: "lrclib_server_url"), text: $draftLrcLibBaseURL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "done")) {
                customLrcLibBaseURL = draftLrcLibBaseURL
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await CloudKitSyncService.shared.recordLyricsServerSettingsChange() }
            }
        }
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
