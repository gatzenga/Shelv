import SwiftUI

private let lyricsHighlightAnimationDuration = 0.12
private let lyricsHighlightRenderLeadMs = 70
private let lyricsHighlightLeadMs = Int(lyricsHighlightAnimationDuration * 1000) + lyricsHighlightRenderLeadMs
private let lyricsNativeActiveLineAnchor = UnitPoint(x: 0.5, y: 0.12)

private struct LyricLine: Identifiable {
    let id: Int
    let timeMs: Int
    let text: String
}

private struct TVNativeLyricLineRow: View {
    let line: LyricLine
    let distance: Int

    private var opacity: Double {
        switch distance {
        case 0:
            return 1.0
        case 1:
            return 0.58
        case 2:
            return 0.36
        default:
            return 0.22
        }
    }

    private var blurRadius: CGFloat {
        switch distance {
        case 0:
            return 0
        case 1:
            return 0.35
        case 2:
            return 1.1
        default:
            return 2.1
        }
    }

    var body: some View {
        Text(line.text)
            .font(.system(size: 44, weight: .bold))
            .lineSpacing(7)
            .foregroundStyle(Color.primary.opacity(opacity))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .blur(radius: blurRadius)
            .padding(.vertical, 7)
            .animation(.easeInOut(duration: lyricsHighlightAnimationDuration), value: distance)
    }
}

private struct TVNativePlainLyricLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 39, weight: .semibold))
            .lineSpacing(7)
            .foregroundStyle(Color.primary.opacity(0.86))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lyrics-Panel der Now-Playing-Ansicht. Synchronisierte LRC laufen automatisch
/// mit (Native-Style: aktive Zeile scharf, entfernte Zeilen weicher), sonst Plaintext.
/// Bewusst ohne eigenen Kopf (Titel/Künstler) — der steht links in der Now-Playing-Spalte.
struct LyricsView: View {
    @ObservedObject var player = AudioPlayerService.shared
    private let horizontalPadding: CGFloat

    @State private var parsedLines: [LyricLine] = []
    @State private var plainLines: [String] = []
    @State private var activeLineIndex: Int? = nil
    @State private var visualActiveLineIndex: Int? = nil
    @State private var initialFocusRequest = 0
    @State private var instrumental = false
    @State private var isLoading = true
    @State private var currentTimeMs = 0
    @State private var lastClockTime: Double = 0
    @State private var lastClockDate = Date()
    @State private var lyricsClockTask: Task<Void, Never>? = nil
    @State private var scheduledLineChangeTask: Task<Void, Never>? = nil
    @State private var scheduledLineChangeIndex: Int?
    @State private var scheduledVisualLineChangeTask: Task<Void, Never>? = nil
    @State private var scheduledVisualLineChangeIndex: Int?
    @State private var scheduledStandardScrollTask: Task<Void, Never>? = nil
    @State private var scheduledStandardScrollIndex: Int?
    @State private var standardPreparedLineIndex: Int?
    @State private var standardPreparedScrollDuration: Double = 0.38

    init(horizontalPadding: CGFloat = 54) {
        self.horizontalPadding = horizontalPadding
    }

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
        // Bei Song-Wechsel SOFORT (synchron) zurücksetzen → Spinner statt altem Zustand,
        // danach lädt `.task` die Lyrics des neuen Songs neu.
        .onChange(of: player.currentSong?.id) { _, _ in
            isLoading = true
            parsedLines = []
            plainLines = []
            instrumental = false
            activeLineIndex = nil
            resetVisualActiveLine()
            resetStandardPreparedScroll()
            syncPlaybackClock(time: player.currentTime)
        }
        .task(id: player.currentSong?.id) { await load() }
        .onAppear {
            syncPlaybackClock(time: player.currentTime)
            startLyricsClock()
        }
        .onChange(of: player.isPlaying) { _, _ in
            syncPlaybackClock(time: player.currentTime)
            updateActiveIndex()
        }
        .onChange(of: player.isBuffering) { _, _ in
            syncPlaybackClock(time: player.currentTime)
            updateActiveIndex()
        }
        .onChange(of: player.isSeeking) { _, _ in
            syncPlaybackClock(time: player.currentTime)
            updateActiveIndex()
        }
        .onReceive(player.timePublisher) { update in
            syncPlaybackClock(time: update.time)
            guard !parsedLines.isEmpty else { return }
            updateActiveIndex()
        }
        .onDisappear {
            lyricsClockTask?.cancel()
            scheduledLineChangeTask?.cancel()
            scheduledVisualLineChangeTask?.cancel()
            scheduledStandardScrollTask?.cancel()
        }
    }

    // MARK: - Synced (Auto-Scroll + Markierung)

    private var syncedView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(parsedLines.enumerated()), id: \.element.id) { index, line in
                        let distance = visualActiveLineIndex.map { abs(index - $0) } ?? 0
                        TVNativeLyricLineRow(line: line, distance: distance)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 90)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
            .edgeFadeMask()
            .onAppear {
                focusCurrentLineSoon(proxy: proxy, anchor: lyricsNativeActiveLineAnchor)
            }
            .onChange(of: initialFocusRequest) { _, _ in
                focusCurrentLineSoon(proxy: proxy, anchor: lyricsNativeActiveLineAnchor)
            }
            .onChange(of: standardPreparedLineIndex) { _, index in
                guard let index, index < parsedLines.count else { return }
                withAnimation(.easeOut(duration: standardPreparedScrollDuration)) {
                    scrollToNativeLine(at: index, proxy: proxy, anchor: lyricsNativeActiveLineAnchor)
                }
            }
            .onChange(of: activeLineIndex) { _, index in
                guard let index, index < parsedLines.count else { return }
                guard standardPreparedLineIndex != index else { return }

                withAnimation(.easeOut(duration: 0.18)) {
                    scrollToNativeLine(at: index, proxy: proxy, anchor: lyricsNativeActiveLineAnchor)
                }
            }
        }
    }

    // MARK: - Plain

    private var plainView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plainLines.enumerated()), id: \.offset) { _, line in
                    TVNativePlainLyricLine(text: line.isEmpty ? " " : line)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 90)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .edgeFadeMask()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Laden & Sync

    private func load() async {
        let songId = player.currentSong?.id
        isLoading = true
        instrumental = false
        parsedLines = []
        plainLines = []
        activeLineIndex = nil
        resetVisualActiveLine()
        resetStandardPreparedScroll()
        syncPlaybackClock(time: player.currentTime)
        guard let song = player.currentSong,
              let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString, !serverId.isEmpty
        else { isLoading = false; return }

        await LyricsService.shared.setup()
        let record = await LyricsService.shared.fetchAndSave(song: song, serverId: serverId)
        // Song kann während des (externen) Fetchs gewechselt haben → veraltetes Ergebnis verwerfen.
        guard player.currentSong?.id == songId else { return }
        instrumental = record.isInstrumental
        if let synced = record.syncedLrc, !synced.isEmpty {
            parsedLines = parseLRC(synced)
        }
        if parsedLines.isEmpty, let plain = plainText(for: record) {
            plainLines = lyricTextLines(from: plain)
        }
        updateActiveIndex()
        isLoading = false
        initialFocusRequest += 1
    }

    private func updateActiveIndex() {
        guard !parsedLines.isEmpty else {
            if activeLineIndex != nil { activeLineIndex = nil }
            resetVisualActiveLine()
            resetStandardPreparedScroll()
            return
        }

        let currentMs = currentTimeMs
        var idx: Int? = nil
        for (i, line) in parsedLines.enumerated() {
            if line.timeMs <= currentMs { idx = i } else { break }
        }

        let previousIndex = activeLineIndex
        if idx != activeLineIndex { activeLineIndex = idx }

        if visualActiveLineIndex == nil ||
            !player.isPlaying ||
            player.isBuffering ||
            player.isSeeking ||
            (previousIndex != idx && visualActiveLineIndex != idx) {
            visualActiveLineIndex = idx
        }

        scheduleUpcomingLineChange()
    }

    private func syncPlaybackClock(time: Double) {
        lastClockTime = max(0, time)
        lastClockDate = Date()
        currentTimeMs = Int(lastClockTime * 1000)
        scheduleUpcomingLineChange(force: true)
    }

    private func estimatedPlaybackTime() -> Double {
        guard player.isPlaying, !player.isBuffering, !player.isSeeking else {
            return lastClockTime
        }
        return lastClockTime + Date().timeIntervalSince(lastClockDate)
    }

    private func startLyricsClock() {
        lyricsClockTask?.cancel()
        lyricsClockTask = Task { @MainActor in
            while !Task.isCancelled {
                if !parsedLines.isEmpty {
                    currentTimeMs = Int(estimatedPlaybackTime() * 1000)
                    updateActiveIndex()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func scheduleUpcomingLineChange(force: Bool = false) {
        guard !parsedLines.isEmpty,
              player.isPlaying,
              !player.isBuffering,
              !player.isSeeking else {
            cancelScheduledLineChange()
            cancelScheduledVisualLineChange()
            cancelScheduledStandardScroll()
            return
        }

        let nowMs = Int(estimatedPlaybackTime() * 1000)
        guard let nextIndex = parsedLines.firstIndex(where: { $0.timeMs > nowMs }) else {
            cancelScheduledLineChange()
            cancelScheduledVisualLineChange()
            cancelScheduledStandardScroll()
            return
        }

        guard force || scheduledLineChangeIndex != nextIndex else { return }

        scheduledLineChangeTask?.cancel()
        scheduledLineChangeIndex = nextIndex

        let delayMs = max(0, parsedLines[nextIndex].timeMs - nowMs)
        scheduleVisualLinePreparation(for: nextIndex, delayMs: delayMs)
        scheduleStandardScrollPreparation(for: nextIndex, delayMs: delayMs)

        scheduledLineChangeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled,
                  parsedLines.indices.contains(nextIndex) else { return }

            currentTimeMs = parsedLines[nextIndex].timeMs
            updateActiveIndex()
        }
    }

    private func cancelScheduledLineChange() {
        scheduledLineChangeTask?.cancel()
        scheduledLineChangeTask = nil
        scheduledLineChangeIndex = nil
    }

    private func scheduleVisualLinePreparation(for index: Int, delayMs: Int) {
        scheduledVisualLineChangeTask?.cancel()
        scheduledVisualLineChangeIndex = index

        let startDelayMs = max(0, delayMs - lyricsHighlightLeadMs)
        scheduledVisualLineChangeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(startDelayMs))
            guard !Task.isCancelled,
                  parsedLines.indices.contains(index),
                  scheduledVisualLineChangeIndex == index else { return }

            visualActiveLineIndex = index
        }
    }

    private func cancelScheduledVisualLineChange() {
        scheduledVisualLineChangeTask?.cancel()
        scheduledVisualLineChangeTask = nil
        scheduledVisualLineChangeIndex = nil
    }

    private func resetVisualActiveLine() {
        cancelScheduledVisualLineChange()
        visualActiveLineIndex = nil
    }

    private func scheduleStandardScrollPreparation(for index: Int, delayMs: Int) {
        scheduledStandardScrollTask?.cancel()
        scheduledStandardScrollIndex = index

        let durationMs = min(260, max(90, delayMs))
        let startDelayMs = max(0, delayMs - durationMs)
        standardPreparedScrollDuration = Double(durationMs) / 1000.0

        scheduledStandardScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(startDelayMs))
            guard !Task.isCancelled,
                  parsedLines.indices.contains(index),
                  scheduledStandardScrollIndex == index else { return }

            standardPreparedLineIndex = index
        }
    }

    private func cancelScheduledStandardScroll() {
        scheduledStandardScrollTask?.cancel()
        scheduledStandardScrollTask = nil
        scheduledStandardScrollIndex = nil
    }

    private func resetStandardPreparedScroll() {
        cancelScheduledStandardScroll()
        standardPreparedLineIndex = nil
        standardPreparedScrollDuration = 0.38
    }

    private func focusCurrentLineSoon(proxy: ScrollViewProxy, anchor: UnitPoint) {
        focusCurrentLine(proxy: proxy, anchor: anchor)
        DispatchQueue.main.async {
            focusCurrentLine(proxy: proxy, anchor: anchor)
        }
    }

    private func focusCurrentLine(proxy: ScrollViewProxy, anchor: UnitPoint) {
        guard let index = visualActiveLineIndex ?? activeLineIndex,
              parsedLines.indices.contains(index) else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollToNativeLine(at: index, proxy: proxy, anchor: anchor)
        }
    }

    private func scrollToNativeLine(at index: Int, proxy: ScrollViewProxy, anchor: UnitPoint) {
        let targetIndex = max(0, index - 2)
        guard parsedLines.indices.contains(targetIndex) else { return }
        proxy.scrollTo(parsedLines[targetIndex].id, anchor: anchor)
    }

    private func parseLRC(_ lrc: String) -> [LyricLine] {
        var result: [(timeMs: Int, text: String)] = []
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for rawLine in lrc.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            let matches = regex.matches(in: line, range: range)
            guard !matches.isEmpty, let lastMatch = matches.last else { continue }

            let textStart = lastMatch.range.location + lastMatch.range.length
            guard textStart <= nsLine.length else { continue }

            let text = nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard match.numberOfRanges >= 4 else { continue }

                func group(_ index: Int) -> String {
                    let groupRange = match.range(at: index)
                    guard groupRange.location != NSNotFound else { return "" }
                    return nsLine.substring(with: groupRange)
                }

                let minutes = Int(group(1)) ?? 0
                let seconds = Int(group(2)) ?? 0
                let fraction = group(3)
                let fractionValue = Int(fraction) ?? 0
                let fractionMs: Int
                switch fraction.count {
                case 1:
                    fractionMs = fractionValue * 100
                case 2:
                    fractionMs = fractionValue * 10
                default:
                    fractionMs = fractionValue
                }

                let totalMs = (minutes * 60 + seconds) * 1000 + fractionMs
                result.append((timeMs: totalMs, text: text))
            }
        }

        return result
            .sorted { $0.timeMs < $1.timeMs }
            .enumerated()
            .map { offset, line in
                LyricLine(id: offset, timeMs: line.timeMs, text: line.text)
            }
    }

    private func plainText(for record: LyricsRecord) -> String? {
        if let plain = record.plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plain.isEmpty {
            return plain
        }

        if let synced = record.syncedLrc {
            let stripped = stripLRCTimestamps(from: synced)
            if !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stripped
            }
        }

        return nil
    }

    private func lyricTextLines(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func stripLRCTimestamps(from lrc: String) -> String {
        let pattern = #"\[\d{1,2}:\d{2}(?:\.\d{1,3})?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return lrc }

        return lrc
            .components(separatedBy: "\n")
            .map { rawLine in
                let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
                return regex
                    .stringByReplacingMatches(in: rawLine, range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
