import SwiftUI

struct RecapPlayLogView: View {
    let serverId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor

    @State private var logs: [PlayLogRecord] = []
    @State private var logCount: Int = 0

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss"
        return f
    }()

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "total_plays")) {
                    Text("\(logCount)").foregroundStyle(.secondary).monospacedDigit()
                }
            }

            Section(String(localized: "recent_plays")) {
                if logs.isEmpty {
                    Text(String(localized: "no_plays_recorded_yet"))
                        .foregroundStyle(.secondary).font(.subheadline)
                } else {
                    ForEach(logs, id: \.uuid) { log in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(log.songId)
                                    .font(.caption.monospaced()).lineLimit(1)
                                HStack {
                                    Text(Self.dateFmt.string(from: Date(timeIntervalSince1970: log.playedAt)))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text("\(Int(log.songDuration))s")
                                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                }
                            }
                            Spacer()
                            if let uuid = log.uuid {
                                Button {
                                    Task {
                                        await PlayLogService.shared.deletePlayLog(uuid: uuid)
                                        await CloudKitSyncService.shared.deletePlayEvent(uuid: uuid)
                                        await CloudKitSyncService.shared.updatePendingCounts()
                                        await refresh()
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .help(String(localized: "delete"))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 540, height: 580)
        .navigationTitle(String(localized: "recent_plays"))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        logs = await PlayLogService.shared.recentLogs(serverId: serverId, limit: 100)
        logCount = await PlayLogService.shared.logCount(serverId: serverId)
    }
}
