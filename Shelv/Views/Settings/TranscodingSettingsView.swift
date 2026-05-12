import SwiftUI

struct TranscodingSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("transcodingWifiCodec") private var wifiCodecRaw: String = "raw"
    @AppStorage("transcodingWifiBitrate") private var wifiBitrate: Int = 256
    @AppStorage("transcodingCellularCodec") private var cellularCodecRaw: String = "raw"
    @AppStorage("transcodingCellularBitrate") private var cellularBitrate: Int = 128
    @AppStorage("transcodingDownloadCodec") private var downloadCodecRaw: String = "raw"
    @AppStorage("transcodingDownloadBitrate") private var downloadBitrate: Int = 192

    @State private var showInfo = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var infoText: String {
        tr("settings.transcoding.settings.choose_format_bitrate_server_should_transcode")
    }

    var body: some View {
        List {
            transcodingSection(
                title: tr("settings.transcoding.settings.wifi"),
                icon: "wifi",
                codecBinding: $wifiCodecRaw,
                bitrateBinding: $wifiBitrate,
                options: TranscodingCodec.streamingOptions
            )

            transcodingSection(
                title: tr("settings.transcoding.settings.cellular"),
                icon: "antenna.radiowaves.left.and.right",
                codecBinding: $cellularCodecRaw,
                bitrateBinding: $cellularBitrate,
                options: TranscodingCodec.streamingOptions
            )

            transcodingSection(
                title: tr("car.play.car.play.library.downloads"),
                icon: "arrow.down.circle",
                codecBinding: $downloadCodecRaw,
                bitrateBinding: $downloadBitrate,
                options: TranscodingCodec.downloadOptions
            )

            Section {
                Button {
                    showInfo = true
                } label: {
                    Label(tr("settings.transcoding.settings.about_transcoding"), systemImage: "info.circle")
                        .foregroundStyle(accentColor)
                }
            }

            PlayerBottomSpacer()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .navigationTitle(tr("settings.settings.transcoding"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(accentColor)
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                ScrollView {
                    Text(infoText)
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(tr("settings.settings.transcoding"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(tr("player.queue.done")) { showInfo = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func transcodingSection(title: String, icon: String,
                                    codecBinding: Binding<String>,
                                    bitrateBinding: Binding<Int>,
                                    options: [TranscodingCodec]) -> some View {
        let codec = TranscodingCodec(rawValue: codecBinding.wrappedValue) ?? .raw
        Section(title) {
            Picker(selection: codecBinding) {
                ForEach(options) { c in
                    Text(c.label).tag(c.rawValue)
                }
            } label: {
                Label { Text(tr("settings.transcoding.settings.format")) } icon: {
                    Image(systemName: icon).foregroundStyle(accentColor)
                }
            }
            if codec != .raw {
                Picker(selection: bitrateBinding) {
                    ForEach(TranscodingBitrate.allCases) { b in
                        Text(b.label).tag(b.rawValue)
                    }
                } label: {
                    Label { Text(tr("settings.transcoding.settings.bitrate")) } icon: {
                        Image(systemName: "speedometer").foregroundStyle(accentColor)
                    }
                }
            }
        }
    }
}
