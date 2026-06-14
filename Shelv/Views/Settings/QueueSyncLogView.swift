import SwiftUI

/// Live-Log des Queue-Syncs (Upload/Download/Übernahme) — beobachtet den QueueSyncService.
struct QueueSyncLogView: View {
    @ObservedObject private var queueSync = QueueSyncService.shared

    var body: some View {
        Group {
            if queueSync.logEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "no_log_entries_yet"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(queueSync.logEntries.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle(String(localized: "queue_sync_log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !queueSync.logEntries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "clear")) { queueSync.clearLog() }
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
