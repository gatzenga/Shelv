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
        }
        .toolbar(.hidden, for: .tabBar)
    }
}
