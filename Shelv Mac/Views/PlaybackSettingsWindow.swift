import SwiftUI

/// Playback-Einstellungen als Tab innerhalb der Haupt-`SettingsView`.
///
/// Die zweite Ebene (Gapless, Transcoding, …) ist bewusst eine eigene Leiste im
/// Content-Bereich, KEIN verschachteltes `TabView`: In der macOS-`Settings`-Scene
/// werden die Tabs eines `TabView` in die Fenster-Toolbar oben gezogen — ein
/// inneres `TabView` landete dort auf gleicher Ebene wie die Hauptleiste. Mit einer
/// eigenen Leiste sitzt die zweite Ebene garantiert UNTER der Haupt-Tableiste.
struct PlaybackTab: View {
    @State private var section: Section = .gapless

    private enum Section: String, CaseIterable, Identifiable {
        case gapless, transcoding, replayGain, scrobble, queueSync, lyrics
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gapless:     return String(localized: "gapless")
            case .transcoding: return String(localized: "transcoding")
            case .replayGain:  return String(localized: "replay_gain")
            case .scrobble:    return String(localized: "scrobble")
            case .queueSync:   return String(localized: "queue_sync")
            case .lyrics:      return String(localized: "lyrics")
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
                case .gapless:     GaplessPanel()
                case .transcoding: TranscodingPanel()
                case .replayGain:  ReplayGainPanel()
                case .scrobble:    ScrobblePanel()
                case .queueSync:   QueueSyncPanel()
                case .lyrics:      LyricsSettingsPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transaction { $0.animation = nil }
    }
}
