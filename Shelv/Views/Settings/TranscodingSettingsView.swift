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
        tr(
            "Choose format and bitrate the server should transcode to. \"Original\" requests the source file unchanged. If the server cannot transcode, the original is returned.\n\nTranscoded songs play from a local copy, ensuring stable playback and seamless gapless transitions. The first song may take longer to load.\n\n• The current song is fully downloaded before playback\n• While it plays, the next song pre-fetches in the background\n• Every subsequent song starts instantly\n• Cached files are removed when the next song starts",
            "Wähle Format und Bitrate die der Server liefern soll. „Original\u{201C} lädt unverändert. Wenn der Server das Format nicht liefert, kommt die Originaldatei zurück.\n\nTranscodierte Songs werden lokal abgespielt – stabile Wiedergabe und nahtlose Gapless-Übergänge. Beim ersten Song kann es zu einer längeren Ladezeit kommen.\n\n• Der aktuelle Song wird vollständig vor der Wiedergabe geladen\n• Währenddessen wird der nächste Song im Hintergrund geladen\n• Ab dem zweiten Song startet die Wiedergabe sofort\n• Gecachte Dateien werden beim Start des nächsten Songs gelöscht"
        )
    }

    var body: some View {
        List {
            transcodingSection(
                title: tr("WiFi", "WLAN"),
                icon: "wifi",
                codecBinding: $wifiCodecRaw,
                bitrateBinding: $wifiBitrate,
                options: TranscodingCodec.streamingOptions
            )

            transcodingSection(
                title: tr("Cellular", "Mobilfunk"),
                icon: "antenna.radiowaves.left.and.right",
                codecBinding: $cellularCodecRaw,
                bitrateBinding: $cellularBitrate,
                options: TranscodingCodec.streamingOptions
            )

            transcodingSection(
                title: tr("Downloads", "Downloads"),
                icon: "arrow.down.circle",
                codecBinding: $downloadCodecRaw,
                bitrateBinding: $downloadBitrate,
                options: TranscodingCodec.downloadOptions
            )

            Section {
                Button {
                    showInfo = true
                } label: {
                    Label(tr("About Transcoding", "Über Transcoding"), systemImage: "info.circle")
                        .foregroundStyle(accentColor)
                }
            }

            PlayerBottomSpacer()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .navigationTitle(tr("Transcoding", "Transcoding"))
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
                .navigationTitle(tr("Transcoding", "Transcoding"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(tr("Done", "Fertig")) { showInfo = false }
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
                Label { Text(tr("Format", "Format")) } icon: {
                    Image(systemName: icon).foregroundStyle(accentColor)
                }
            }
            if codec != .raw {
                Picker(selection: bitrateBinding) {
                    ForEach(TranscodingBitrate.allCases) { b in
                        Text(b.label).tag(b.rawValue)
                    }
                } label: {
                    Label { Text(tr("Bitrate", "Bitrate")) } icon: {
                        Image(systemName: "speedometer").foregroundStyle(accentColor)
                    }
                }
            }
        }
    }
}
