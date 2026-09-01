import SwiftUI

struct TranscodingSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("transcodingWifiCodec") private var wifiCodecRaw: String = "raw"
    @AppStorage("transcodingWifiBitrate") private var wifiBitrate: Int = 256
    @AppStorage("transcodingCellularCodec") private var cellularCodecRaw: String = "raw"
    @AppStorage("transcodingCellularBitrate") private var cellularBitrate: Int = 128
    @AppStorage("transcodingPrimaryURLExempt") private var primaryURLExempt = false
    @ObservedObject private var serverStore = ServerStore.shared

    @State private var showInfo = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var infoText: String {
        String(localized: "about_transcoding_details")
    }

    var body: some View {
        List {
            transcodingSection(
                title: String(localized: "wifi"),
                icon: "wifi",
                codecBinding: $wifiCodecRaw,
                bitrateBinding: $wifiBitrate,
                options: TranscodingCodec.streamingOptions
            )

            // Only shown for a server that has both URLs: with a single URL the
            // toggle would just mean "never transcode on Wi-Fi", which the
            // Wi-Fi profile already says.
            if serverStore.activeServer?.hasSecondaryURL == true {
                Section {
                    Toggle(String(localized: "transcoding_primary_url_exempt"), isOn: $primaryURLExempt)
                } footer: {
                    Text(String(localized: "transcoding_primary_url_exempt_footer"))
                }
            }

            transcodingSection(
                title: String(localized: "cellular"),
                icon: "antenna.radiowaves.left.and.right",
                codecBinding: $cellularCodecRaw,
                bitrateBinding: $cellularBitrate,
                options: TranscodingCodec.streamingOptions
            )

            Section {
                Button {
                    showInfo = true
                } label: {
                    Label(String(localized: "about_transcoding"), systemImage: "info.circle")
                        .foregroundStyle(accentColor)
                }
            }

            PlayerBottomSpacer()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .navigationTitle(String(localized: "transcoding"))
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
                .navigationTitle(String(localized: "transcoding"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "done")) { showInfo = false }
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
                Label { Text(String(localized: "format")) } icon: {
                    Image(systemName: icon).foregroundStyle(accentColor)
                }
            }
            if codec != .raw {
                Picker(selection: bitrateBinding) {
                    ForEach(TranscodingBitrate.allCases) { b in
                        Text(b.label).tag(b.rawValue)
                    }
                } label: {
                    Label { Text(String(localized: "bitrate")) } icon: {
                        Image(systemName: "speedometer").foregroundStyle(accentColor)
                    }
                }
            }
        }
    }
}
