import SwiftUI

struct GaplessPanel: View {
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $gaplessEnabled) {
                    Label(String(localized: "gapless_playback"), systemImage: "music.note.list")
                }
                .tint(themeColor)
                Text(String(localized: "precache_original_file_recommendedntranscoded_stre"))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
