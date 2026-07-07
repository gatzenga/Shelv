import SwiftUI
import AppKit

private let lyricsHighlightAnimationDuration = 0.12
private let lyricsHighlightRenderLeadMs = 70
private let lyricsHighlightLeadMs = Int(lyricsHighlightAnimationDuration * 1000) + lyricsHighlightRenderLeadMs
private let lyricsStandardActiveLineAnchor = UnitPoint(x: 0.5, y: 0.2)

private struct LyricLine: Identifiable {
    let id: Int
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
        .animation(.easeOut(duration: lyricsHighlightAnimationDuration), value: isActive)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }
}

struct LyricsPanel: View {
    @ObservedObject private var player = AudioPlayerService.shared
    @EnvironmentObject var lyricsStore: LyricsStore
    @Environment(\.themeColor) private var themeColor

    @State private var parsedLines: [LyricLine] = []
    @State private var activeLineIndex: Int? = nil
    @State private var visualActiveLineIndex: Int? = nil
    @State private var isUserScrolling = false
    @State private var autoScrollRefocusRequest = 0
    @State private var initialFocusRequest = 0
    @State private var currentTimeMs: Int = 0
    @State private var lastClockTime: Double = 0
    @State private var lastClockDate = Date()
    @State private var resumeScrollTask: Task<Void, Never>? = nil
    @State private var lyricsClockTask: Task<Void, Never>? = nil
    @State private var scheduledLineChangeTask: Task<Void, Never>? = nil
    @State private var scheduledLineChangeIndex: Int?
    @State private var scheduledVisualLineChangeTask: Task<Void, Never>? = nil
    @State private var scheduledVisualLineChangeIndex: Int?
    @State private var scheduledStandardScrollTask: Task<Void, Never>? = nil
    @State private var scheduledStandardScrollIndex: Int?
    @State private var standardPreparedLineIndex: Int?
    @State private var standardPreparedScrollDuration: Double = 0.38

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
            syncPlaybackClock(time: player.currentTime)
            rebuildLines()
            startLyricsClock()
            triggerLyricsLoad()
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            activeLineIndex = nil
            resetVisualActiveLine()
            parsedLines = []
            resetStandardPreparedScroll()
            syncPlaybackClock(time: player.currentTime)
            triggerLyricsLoad()
        }
        .onChange(of: lyricsStore.currentLyrics?.songId) { _, _ in
            activeLineIndex = nil
            resetVisualActiveLine()
            resetStandardPreparedScroll()
            rebuildLines()
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
            guard lyricsStore.currentLyrics?.isSynced == true, !parsedLines.isEmpty else { return }
            updateActiveIndex()
        }
        .onDisappear {
            resumeScrollTask?.cancel()
            lyricsClockTask?.cancel()
            scheduledLineChangeTask?.cancel()
            scheduledVisualLineChangeTask?.cancel()
            scheduledStandardScrollTask?.cancel()
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
            } else if record.isSynced, !parsedLines.isEmpty {
                syncedView
            } else if let plain = plainText(for: record) {
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
        let lines = lyricTextLines(from: plain)
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
                        let isActive = visualActiveLineIndex == index
                        LyricLineRow(
                            line: line,
                            isActive: isActive,
                            themeColor: themeColor,
                            onTap: {
                                let seconds = Double(line.timeMs) / 1000.0
                                player.seek(to: seconds)
                                syncPlaybackClock(time: seconds)
                                updateActiveIndex()
                                visualActiveLineIndex = index
                                isUserScrolling = false
                                withAnimation(.easeOut(duration: 0.12)) {
                                    proxy.scrollTo(line.id, anchor: lyricsStandardActiveLineAnchor)
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
            .overlay {
                MacLyricsScrollActivityObserver(onScroll: pauseAutoScroll)
                    .allowsHitTesting(false)
            }
            .onAppear {
                focusCurrentLineSoon(proxy: proxy, anchor: lyricsStandardActiveLineAnchor)
            }
            .onChange(of: initialFocusRequest) { _, _ in
                guard !isUserScrolling else { return }
                focusCurrentLineSoon(proxy: proxy, anchor: lyricsStandardActiveLineAnchor)
            }
            .onChange(of: standardPreparedLineIndex) { _, index in
                guard !isUserScrolling,
                      let index,
                      parsedLines.indices.contains(index) else { return }

                withAnimation(.easeOut(duration: standardPreparedScrollDuration)) {
                    proxy.scrollTo(parsedLines[index].id, anchor: lyricsStandardActiveLineAnchor)
                }
            }
            .onChange(of: activeLineIndex) { _, index in
                guard !isUserScrolling, let index, index < parsedLines.count else { return }
                guard standardPreparedLineIndex != index else { return }

                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(parsedLines[index].id, anchor: lyricsStandardActiveLineAnchor)
                }
            }
            .onChange(of: autoScrollRefocusRequest) { _, _ in
                guard !isUserScrolling,
                      let index = activeLineIndex,
                      parsedLines.indices.contains(index) else { return }

                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(parsedLines[index].id, anchor: lyricsStandardActiveLineAnchor)
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
        updateActiveIndex()
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
                if lyricsStore.currentLyrics?.isSynced == true, !parsedLines.isEmpty {
                    currentTimeMs = Int(estimatedPlaybackTime() * 1000)
                    updateActiveIndex()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func scheduleUpcomingLineChange(force: Bool = false) {
        guard lyricsStore.currentLyrics?.isSynced == true,
              !parsedLines.isEmpty,
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
            proxy.scrollTo(parsedLines[index].id, anchor: anchor)
        }
    }

    private func pauseAutoScroll() {
        isUserScrolling = true
        resumeScrollTask?.cancel()
        resumeScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isUserScrolling = false
            autoScrollRefocusRequest += 1
        }
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

private struct MacLyricsScrollActivityObserver: NSViewRepresentable {
    let onScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class ObserverView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onScroll: () -> Void
        private var monitor: Any?

        init(onScroll: @escaping () -> Void) {
            self.onScroll = onScroll
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            guard let view,
                  let window = view.window,
                  event.window === window,
                  abs(event.scrollingDeltaX) > 0.1 || abs(event.scrollingDeltaY) > 0.1 else { return }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return }

            onScroll()
        }
    }
}
