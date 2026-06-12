import SwiftUI

/// Lyrics-Vollbild. Lädt via LyricsService (Navidrome/lrclib, Cache-DB nicht
/// persistenzkritisch). Zeigt den Text scrollbar; Zeit-Sync/Auto-Scroll später.
struct LyricsView: View {
    @ObservedObject var player = AudioPlayerService.shared

    @State private var lines: [String] = []
    @State private var instrumental = false
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let song = player.currentSong {
                    Text(song.title).font(.title2).bold()
                    if let artist = song.artist {
                        Text(artist).font(.title3).foregroundStyle(.secondary)
                    }
                }
                Divider().frame(maxWidth: 600)

                if isLoading {
                    ProgressView().padding(.top, 40)
                } else if instrumental {
                    Text(String(localized: "instrumental")).font(.title3).foregroundStyle(.secondary)
                } else if lines.isEmpty {
                    Text(String(localized: "no_lyrics")).font(.title3).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
            .padding(.horizontal, 120)
        }
        .task(id: player.currentSong?.id) { await load() }
    }

    private func load() async {
        isLoading = true
        instrumental = false
        lines = []
        guard let song = player.currentSong,
              let serverId = SubsonicAPIService.shared.activeServer?.stableId, !serverId.isEmpty
        else { isLoading = false; return }

        await LyricsService.shared.setup()
        let record = await LyricsService.shared.fetchAndSave(song: song, serverId: serverId)
        instrumental = record.isInstrumental
        if let synced = record.syncedLrc, !synced.isEmpty {
            lines = synced.components(separatedBy: "\n").map(stripTimestamp)
        } else if let plain = record.plainText, !plain.isEmpty {
            lines = plain.components(separatedBy: "\n")
        }
        isLoading = false
    }

    /// Entfernt führende LRC-Zeitstempel `[mm:ss.xx]`.
    private func stripTimestamp(_ line: String) -> String {
        guard let close = line.firstIndex(of: "]"), line.hasPrefix("[") else { return line }
        return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }
}
