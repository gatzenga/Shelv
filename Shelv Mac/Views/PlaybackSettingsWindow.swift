import SwiftUI

/// Playback-Einstellungen als Tab innerhalb der Haupt-`SettingsView`.
///
/// Die zweite Ebene (Transcoding, Gapless, …) ist bewusst eine eigene Leiste im
/// Content-Bereich, KEIN verschachteltes `TabView`: In der macOS-`Settings`-Scene
/// werden die Tabs eines `TabView` in die Fenster-Toolbar oben gezogen — ein
/// inneres `TabView` landete dort auf gleicher Ebene wie die Hauptleiste. Mit einer
/// eigenen Leiste sitzt die zweite Ebene garantiert UNTER der Haupt-Tableiste.
struct PlaybackTab: View {
    @State private var section: Section = .transcoding

    private enum Section: String, CaseIterable, Identifiable {
        case transcoding, gapless, replayGain, scrobble, queueSync, infinityMix
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcoding: return String(localized: "transcoding")
            case .gapless:     return String(localized: "gapless")
            case .replayGain:  return String(localized: "replay_gain")
            case .scrobble:    return String(localized: "scrobble")
            case .queueSync:   return String(localized: "queue_sync")
            case .infinityMix: return String(localized: "infinity_mix")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch section {
                case .transcoding: TranscodingPanel()
                case .gapless:     GaplessPanel()
                case .replayGain:  ReplayGainPanel()
                case .scrobble:    ScrobblePanel()
                case .queueSync:   QueueSyncPanel()
                case .infinityMix: InfinityMixPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transaction { $0.animation = nil }
    }
}
