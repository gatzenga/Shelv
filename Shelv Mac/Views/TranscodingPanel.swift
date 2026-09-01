import SwiftUI

struct TranscodingPanel: View {
    @AppStorage("transcodingEnabled") private var transcodingEnabled = false
    @AppStorage("transcodingWifiCodec") private var wifiCodecRaw: String = "raw"
    @AppStorage("transcodingWifiBitrate") private var wifiBitrate: Int = 256
    @AppStorage("transcodingCellularCodec") private var cellularCodecRaw: String = "raw"
    @AppStorage("transcodingCellularBitrate") private var cellularBitrate: Int = 128
    @AppStorage("transcodingPrimaryURLExempt") private var primaryURLExempt = false
    @ObservedObject private var serverStore = ServerStore.shared
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $transcodingEnabled) {
                    Label(String(localized: "transcoding"), systemImage: "waveform.badge.magnifyingglass")
                }
                .tint(themeColor)
                if transcodingEnabled {
                    Text(String(localized: "server_transcodes_to_the_formatbitrate_below_u201c"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(String(localized: "transcoded_songs_play_from_a_local_copy_ensuring_s"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if transcodingEnabled {
                subsection(title: String(localized: "wifi"),
                           codecBinding: $wifiCodecRaw,
                           bitrateBinding: $wifiBitrate,
                           options: TranscodingCodec.streamingOptions)

                // Only shown for a server that has both URLs: with a single URL
                // the toggle would just mean "never transcode on Wi-Fi", which
                // the Wi-Fi profile already says.
                if serverStore.activeServer?.hasSecondaryURL == true {
                    Section {
                        Toggle(String(localized: "transcoding_primary_url_exempt"), isOn: $primaryURLExempt)
                            .tint(themeColor)
                    } footer: {
                        Text(String(localized: "transcoding_primary_url_exempt_footer"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                subsection(title: String(localized: "data_saver"),
                           codecBinding: $cellularCodecRaw,
                           bitrateBinding: $cellularBitrate,
                           options: TranscodingCodec.streamingOptions)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func subsection(title: String,
                            codecBinding: Binding<String>,
                            bitrateBinding: Binding<Int>,
                            options: [TranscodingCodec]) -> some View {
        let codec = TranscodingCodec(rawValue: codecBinding.wrappedValue) ?? .raw
        Section(title) {
            Picker(String(localized: "format"), selection: codecBinding) {
                ForEach(options) { c in
                    Text(c.label).tag(c.rawValue)
                }
            }
            if codec != .raw {
                Picker(String(localized: "bitrate"), selection: bitrateBinding) {
                    ForEach(TranscodingBitrate.allCases) { b in
                        Text(b.label).tag(b.rawValue)
                    }
                }
            }
        }
    }
}
