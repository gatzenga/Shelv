import SwiftUI

private struct LyricLine: Identifiable {
    let id = UUID()
    let timeMs: Int
    let text: String
}

private struct LyricLineRow: View {
    let line: LyricLine
    let isActive: Bool
    let themeColor: Color
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text(line.text)
                .font(.callout)
                .foregroundStyle(isActive ? Color.primary : (isHovered ? Color.primary : Color.secondary))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 6)
                    .fill(themeColor.opacity(0.15))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }
}

struct LyricsPanel: View {
    @ObservedObject private var player = AudioPlayerService.shared
    @EnvironmentObject var lyricsStore: LyricsStore
    @Environment(\.themeColor) private var themeColor

    @State private var parsedLines: [LyricLine] = []
    @State private var activeLineIndex: Int? = nil
    @State private var isUserScrolling = false
    @State private var currentTimeMs: Int = 0
    @State private var resumeScrollTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "lyrics"))
                    .font(.headline)
                Spacer()
                if let source = lyricsStore.currentLyrics?.source, source != "none" {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            lyricsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            rebuildLines()
            triggerLyricsLoad()
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            activeLineIndex = nil
            parsedLines = []
            triggerLyricsLoad()
        }
        .onChange(of: lyricsStore.currentLyrics?.songId) { _, _ in
            activeLineIndex = nil
            rebuildLines()
        }
        .onReceive(player.timePublisher) { update in
            currentTimeMs = Int(update.time * 1000)
            guard lyricsStore.currentLyrics?.isSynced == true, !parsedLines.isEmpty else { return }
            updateActiveIndex()
        }
        .onDisappear {
            resumeScrollTask?.cancel()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var lyricsContent: some View {
        if lyricsStore.isLoadingLyrics {
            placeholderView(icon: nil, isLoading: true, text: "")
        } else if let record = lyricsStore.currentLyrics {
            if record.isInstrumental {
                placeholderView(icon: "pianokeys", isLoading: false, text: String(localized: "instrumental"))
            } else if record.isSynced {
                syncedView
            } else if let plain = record.plainText, !plain.isEmpty {
                plainView(plain)
            } else {
                placeholderView(icon: "text.page.slash", isLoading: false, text: String(localized: "no_lyrics_available"))
            }
        } else {
            placeholderView(icon: "text.page.slash", isLoading: false, text: String(localized: "no_lyrics_available"))
        }
    }

    private func placeholderView(icon: String?, isLoading: Bool, text: String) -> some View {
        VStack(spacing: 10) {
            if isLoading {
                ProgressView()
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Plain lyrics

    private func plainView(_ plain: String) -> some View {
        let lines = plain.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Synced lyrics

    private var syncedView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(parsedLines.enumerated()), id: \.element.id) { index, line in
                        let isActive = activeLineIndex == index
                        LyricLineRow(
                            line: line,
                            isActive: isActive,
                            themeColor: themeColor,
                            onTap: {
                                let seconds = Double(line.timeMs) / 1000.0
                                player.seek(to: seconds)
                                isUserScrolling = false
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    proxy.scrollTo(line.id, anchor: .center)
                                }
                            }
                        )
                        .id(line.id)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in pauseAutoScroll() }
            )
            .onChange(of: activeLineIndex) { _, index in
                guard !isUserScrolling, let index, index < parsedLines.count else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(parsedLines[index].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Logic

    private func triggerLyricsLoad() {
        guard let song = player.currentSong,
              let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString
        else { return }
        lyricsStore.loadLyrics(for: song, serverId: serverId)
    }

    private func rebuildLines() {
        parsedLines = lyricsStore.currentLyrics?.syncedLrc.map(parseLRC) ?? []
    }

    private func updateActiveIndex() {
        let currentMs = currentTimeMs
        var idx = 0
        for (i, line) in parsedLines.enumerated() {
            if line.timeMs <= currentMs { idx = i } else { break }
        }
        if idx != activeLineIndex { activeLineIndex = idx }
    }

    private func pauseAutoScroll() {
        isUserScrolling = true
        resumeScrollTask?.cancel()
        resumeScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isUserScrolling = false
        }
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
