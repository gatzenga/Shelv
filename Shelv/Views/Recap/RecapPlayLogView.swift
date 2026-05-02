import SwiftUI

struct RecapPlayLogView: View {
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
        List {
            Section {
                HStack {
                    Text(tr("Total plays", "Gesamte Plays"))
                    Spacer()
                    Text("\(logCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Section(tr("Recent plays", "Letzte Plays")) {
                if logs.isEmpty {
                    Text(tr("No plays recorded yet.", "Noch keine Plays aufgezeichnet."))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(logs, id: \.uuid) { log in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.songId)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            HStack {
                                Text(Self.dateFmt.string(from: Date(timeIntervalSince1970: log.playedAt)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(log.songDuration))s")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 2)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if let uuid = log.uuid {
                                Button(role: .destructive) {
                                    Task {
                                        haptic(); await PlayLogService.shared.deletePlayLog(uuid: uuid)
                                        await CloudKitSyncService.shared.deletePlayEvent(uuid: uuid)
                                        await CloudKitSyncService.shared.updatePendingCounts()
                                        await refresh()
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }
            }

            PlayerBottomSpacer(activeHeight: 110, inactiveHeight: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .refreshable { await refresh() }
        .navigationTitle(tr("Recent plays", "Letzte Plays"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        logs = await PlayLogService.shared.recentLogs(serverId: serverId, limit: 100)
        logCount = await PlayLogService.shared.logCount(serverId: serverId)
    }
}
