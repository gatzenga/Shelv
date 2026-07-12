import AppIntents
import SwiftUI

struct SiriShortcutsSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section {
                Text(String(localized: "siri_shortcuts_intro"))
                    .foregroundStyle(.secondary)

                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
            }

            Section(String(localized: "siri_shortcuts_actions")) {
                capability("play.fill", "siri_shortcuts_action_music")
                capability("shuffle", "siri_shortcuts_action_mixes")
                capability("arrow.down.circle.fill", "siri_shortcuts_action_downloads")
                capability("dot.radiowaves.left.and.right", "siri_shortcuts_action_radio")
                capability("playpause.fill", "siri_shortcuts_action_controls")
            }

            Section {
                instruction(number: 1, key: "siri_shortcuts_carplay_step_1")
                instruction(number: 2, key: "siri_shortcuts_carplay_step_2")
                instruction(number: 3, key: "siri_shortcuts_carplay_step_3")
                instruction(number: 4, key: "siri_shortcuts_carplay_step_4")
            } header: {
                Text(String(localized: "siri_shortcuts_carplay_title"))
            } footer: {
                Text(String(localized: "siri_shortcuts_carplay_footer"))
            }
        }
        .navigationTitle(String(localized: "siri_shortcuts"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func capability(_ systemImage: String, _ key: LocalizedStringResource) -> some View {
        Label {
            Text(String(localized: key))
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(accentColor)
        }
    }

    private func instruction(number: Int, key: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(accentColor, in: Circle())
            Text(String(localized: key))
        }
        .padding(.vertical, 2)
    }
}
