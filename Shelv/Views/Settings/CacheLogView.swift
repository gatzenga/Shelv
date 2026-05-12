import SwiftUI

struct CacheLogView: View {
    @StateObject private var cacheLog = StreamCacheLog.shared

    var body: some View {
        if cacheLog.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(tr("settings.cache.log.no_cache_events_yet"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(tr("settings.cache.log.cache_log"))
            .navigationBarTitleDisplayMode(.inline)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .navigationTitle(tr("settings.cache.log.cache_log"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("player.queue.clear.9529e8af")) { StreamCacheLog.shared.clear() }
                }
            }
        }
    }
}
