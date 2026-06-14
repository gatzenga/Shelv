import SwiftUI

/// Live-Log des Queue-Syncs (Upload/Download/Übernahme) — als Sheet aus dem Queue-Panel.
struct QueueSyncLogView: View {
    @ObservedObject private var queueSync = QueueSyncService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if queueSync.logEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "no_log_entries_yet"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(queueSync.logEntries, id: \.self) { entry in
                            Text(entry)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 640, height: 520)
        .navigationTitle(String(localized: "queue_sync_log"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
        }
    }
}
