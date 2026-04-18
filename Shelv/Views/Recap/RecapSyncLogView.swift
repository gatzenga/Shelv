import SwiftUI

struct RecapSyncLogView: View {
    @EnvironmentObject var ckStatus: CloudKitSyncStatus

    var body: some View {
        Group {
            if ckStatus.debugLogEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(tr("No log entries yet.", "Noch keine Log-Einträge."))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(ckStatus.debugLogEntries, id: \.self) { entry in
                            Text(entry)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle(tr("Sync log", "Sync-Protokoll"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
