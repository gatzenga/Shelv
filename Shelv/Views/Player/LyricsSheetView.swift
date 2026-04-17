import SwiftUI
import Combine

private struct LyricLine: Identifiable {
    let id = UUID()
    let timeMs: Int
    let text: String
}

struct LyricsSheetView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @EnvironmentObject var lyricsStore: LyricsStore
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    @State private var parsedLines: [LyricLine] = []
    @State private var activeLineIndex: Int? = nil
    @State private var isUserScrolling = false
    @State private var resumeScrollTask: Task<Void, Never>? = nil

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        VStack(spacing: 0) {
            lyricsContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomControls
        }
        .navigationTitle(tr("Lyrics", "Lyrics"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear { rebuildLines() }
        .task(id: player.currentSong?.id) {
            guard let song = player.currentSong,
                  let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString else { return }
            lyricsStore.loadLyrics(for: song, serverId: serverId)
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            activeLineIndex = nil
            parsedLines = []
        }
        .onChange(of: lyricsStore.currentLyrics?.songId) { _, _ in
            activeLineIndex = nil
            rebuildLines()
        }
        .onReceive(timer) { _ in
            guard lyricsStore.currentLyrics?.isSynced == true, !parsedLines.isEmpty else { return }
            updateActiveIndex()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var lyricsContent: some View {
        if lyricsStore.isLoadingLyrics {
            ProgressView()
        } else if let record = lyricsStore.currentLyrics {
            if record.isInstrumental {
                placeholderView(icon: "pianokeys", text: tr("Instrumental", "Instrumental"))
            } else if record.isSynced, !parsedLines.isEmpty {
                syncedView
            } else if let plain = record.plainText, !plain.isEmpty {
                plainView(plain)
            } else {
                placeholderView(icon: "text.page.slash", text: tr("No lyrics available", "Keine Lyrics verfügbar"))
            }
        } else {
            placeholderView(icon: "text.page.slash", text: tr("No lyrics available", "Keine Lyrics verfügbar"))
        }
    }

    private func placeholderView(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Plain

    private func plainView(_ plain: String) -> some View {
        let lines = plain.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.body)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 16)
        }
    }

    // MARK: - Synced

    private var syncedView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(parsedLines.enumerated()), id: \.element.id) { index, line in
                        let isActive = activeLineIndex == index
                        Text(line.text)
                            .font(isActive ? .body.weight(.semibold) : .body)
                            .foregroundStyle(isActive ? Color.primary : Color.secondary)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                if isActive {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(accentColor.opacity(0.15))
                                }
                            }
                            .animation(.easeInOut(duration: 0.2), value: isActive)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 16)
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

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: isPad ? 48 : 40) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: isPad ? 28 : 24))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(accentColor)
                        .frame(width: isPad ? 64 : 54)
                    if player.isBuffering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: isPad ? 26 : 22))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: accentColor.opacity(0.35), radius: 8, y: 4)
            }
            .buttonStyle(.plain)

            Button { player.next(triggeredByUser: true) } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: isPad ? 28 : 24))
                    .foregroundStyle(player.hasNextTrack ? Color.primary : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!player.hasNextTrack)
        }
        .padding(.vertical, isPad ? 24 : 20)
    }

    // MARK: - Logic

    private func rebuildLines() {
        parsedLines = lyricsStore.currentLyrics?.syncedLrc.map(parseLRC) ?? []
    }

    private func updateActiveIndex() {
        let currentMs = Int(player.currentTime * 1000)
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
