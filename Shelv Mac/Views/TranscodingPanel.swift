import SwiftUI

struct TranscodingPanel: View {
    @AppStorage("transcodingEnabled") private var transcodingEnabled = false
    @AppStorage("transcodingWifiCodec") private var wifiCodecRaw: String = "raw"
    @AppStorage("transcodingWifiBitrate") private var wifiBitrate: Int = 256
    @AppStorage("transcodingCellularCodec") private var cellularCodecRaw: String = "raw"
    @AppStorage("transcodingCellularBitrate") private var cellularBitrate: Int = 128
    @AppStorage("transcodingDownloadCodec") private var downloadCodecRaw: String = "raw"
    @AppStorage("transcodingDownloadBitrate") private var downloadBitrate: Int = 192
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
                subsection(title: String(localized: "data_saver"),
                           codecBinding: $cellularCodecRaw,
                           bitrateBinding: $cellularBitrate,
                           options: TranscodingCodec.streamingOptions)
                subsection(title: String(localized: "downloads"),
                           codecBinding: $downloadCodecRaw,
                           bitrateBinding: $downloadBitrate,
                           options: TranscodingCodec.downloadOptions)
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
