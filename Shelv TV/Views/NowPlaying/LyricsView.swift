import SwiftUI

private struct LyricLine: Identifiable {
    let id = UUID()
    let timeMs: Int
    let text: String
}

/// Lyrics-Panel der Now-Playing-Ansicht. Synchronisierte LRC laufen automatisch
/// mit (aktive Zeile mit Akzentfarbe hinterlegt + zentriert gescrollt), sonst Plaintext.
/// Bewusst ohne eigenen Kopf (Titel/Künstler) — der steht links in der Now-Playing-Spalte.
struct LyricsView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColor = "violet"
    private var accent: Color { AppTheme.color(for: themeColor) }

    @State private var parsedLines: [LyricLine] = []
    @State private var plainLines: [String] = []
    @State private var activeLineIndex: Int? = nil
    @State private var instrumental = false
    @State private var isLoading = true
    @State private var currentTimeMs = 0

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if instrumental {
                placeholder(String(localized: "instrumental"))
            } else if !parsedLines.isEmpty {
                syncedView
            } else if !plainLines.isEmpty {
                plainView
            } else {
                placeholder(String(localized: "no_lyrics"))
            }
        }
        .task(id: player.currentSong?.id) { await load() }
        .onReceive(player.timePublisher) { update in
            currentTimeMs = Int(update.time * 1000)
            guard !parsedLines.isEmpty else { return }
            updateActiveIndex()
        }
    }

    // MARK: - Synced (Auto-Scroll + Markierung)

    private var syncedView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(parsedLines.enumerated()), id: \.element.id) { index, line in
                        let isActive = activeLineIndex == index
                        Text(line.text)
                            .font(.title3)
                            .foregroundStyle(isActive ? Color.primary : Color.secondary)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                if isActive {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(accent.opacity(0.18))
                                }
                            }
                            .animation(.easeInOut(duration: 0.2), value: isActive)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 90)
            }
            .scrollIndicators(.hidden)
            .mask(edgeFade)
            .onChange(of: activeLineIndex) { _, index in
                guard let index, index < parsedLines.count else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(parsedLines[index].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Plain

    private var plainView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plainLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 90)
        }
        .scrollIndicators(.hidden)
        .mask(edgeFade)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sanftes Aus-/Einblenden an Ober- und Unterkante, damit Text nicht hart
    /// hinter der Tab-Leiste bzw. am unteren Rand abreißt.
    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: - Laden & Sync

    private func load() async {
        isLoading = true
        instrumental = false
        parsedLines = []
        plainLines = []
        activeLineIndex = nil
        guard let song = player.currentSong,
              let serverId = SubsonicAPIService.shared.activeServer?.stableId, !serverId.isEmpty
        else { isLoading = false; return }

        await LyricsService.shared.setup()
        let record = await LyricsService.shared.fetchAndSave(song: song, serverId: serverId)
        instrumental = record.isInstrumental
        if let synced = record.syncedLrc, !synced.isEmpty {
            parsedLines = parseLRC(synced)
        }
        if parsedLines.isEmpty, let plain = record.plainText, !plain.isEmpty {
            plainLines = plain.components(separatedBy: "\n")
        }
        isLoading = false
    }

    private func updateActiveIndex() {
        let currentMs = currentTimeMs
        var idx = 0
        for (i, line) in parsedLines.enumerated() {
            if line.timeMs <= currentMs { idx = i } else { break }
        }
        if idx != activeLineIndex { activeLineIndex = idx }
    }

    private func parseLRC(_ lrc: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let pattern = #"^\[(\d{1,2}):(\d{2})\.(\d{2,3})\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for rawLine in lrc.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 5 else { continue }
            func g(_ i: Int) -> String {
                let r = match.range(at: i)
                guard r.location != NSNotFound else { return "" }
                return nsLine.substring(with: r)
            }
            let minutes = Int(g(1)) ?? 0
            let seconds = Int(g(2)) ?? 0
            let fracStr = g(3)
            let frac = Int(fracStr) ?? 0
            let fracMs = fracStr.count == 2 ? frac * 10 : frac
            let totalMs = (minutes * 60 + seconds) * 1000 + fracMs
            let text = g(4).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                result.append(LyricLine(timeMs: totalMs, text: text))
            }
        }
        return result.sorted { $0.timeMs < $1.timeMs }
    }
}
