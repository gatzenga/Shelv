import SwiftUI

struct PlayLogView: View {
    let serverId: String
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var logs: [PlayLogRecord] = []
    @State private var logCount: Int = 0

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "recent_plays"))
                    .font(.largeTitle).bold()
                    .padding(.horizontal, 50)
                    .padding(.bottom, 4)

                HStack {
                    Text(String(localized: "total_plays"))
                    Spacer()
                    Text("\(logCount)").foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 50)
                .padding(.bottom, 16)

                if logs.isEmpty {
                    ContentUnavailableView(String(localized: "no_plays_recorded_yet"), systemImage: "music.note.list")
                        .focusable()
                } else {
                    ForEach(logs, id: \.uuid) { log in
                        PlayLogRow(log: log, accentColor: accentColor, dateFmt: Self.dateFmt)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .toolbar(.hidden, for: .tabBar)
        .task { await refresh() }
    }

    private func refresh() async {
        logs = await PlayLogService.shared.recentLogs(serverId: serverId, limit: 100)
        logCount = await PlayLogService.shared.logCount(serverId: serverId)
    }
}

private struct PlayLogRow: View {
    let log: PlayLogRecord
    let accentColor: Color
    let dateFmt: DateFormatter
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = log.songTitle, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                let subtitle = [log.artistName, log.albumName].compactMap { $0 }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(log.songId)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack {
                Text(dateFmt.string(from: Date(timeIntervalSince1970: log.playedAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(log.songDuration))s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(focused ? accentColor.opacity(0.4) : .clear)
        )
        .padding(.horizontal, 38)
        .focusable()
        .focused($focused)
    }
}
