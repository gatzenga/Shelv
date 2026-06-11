import SwiftUI

struct CacheLogView: View {
    @ObservedObject private var cacheLog = StreamCacheLog.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if cacheLog.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "no_cache_events_yet"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(cacheLog.entries.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle(String(localized: "cache_log"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "clear")) { StreamCacheLog.shared.clear() }
                    .disabled(cacheLog.entries.isEmpty)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
        }
    }
}
