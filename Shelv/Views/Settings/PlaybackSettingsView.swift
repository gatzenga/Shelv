import SwiftUI

struct PlaybackSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @AppStorage("transcodingEnabled") private var transcodingEnabled = false

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
