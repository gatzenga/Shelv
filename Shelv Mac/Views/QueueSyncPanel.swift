import SwiftUI

/// Playback-Settings-Tab „Queue" (macOS): Auswahl der Sync-Methode + direkt sichtbare
/// Erklärung (kein Aufklappen nötig).
struct QueueSyncPanel: View {
    @AppStorage("queueSyncMode") private var queueSyncMode = "off"
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Picker(selection: $queueSyncMode) {
                    Text(String(localized: "queue_sync_off")).tag("off")
                    Text(String(localized: "queue_sync_subsonic")).tag("subsonic")
                    Text(String(localized: "queue_sync_icloud")).tag("icloud")
                } label: {
                    Label(String(localized: "queue_sync"), systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(themeColor)
            }

            Section(String(localized: "about")) {
                Text(String(localized: "queue_sync_about_icloud"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "queue_sync_about_subsonic"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
