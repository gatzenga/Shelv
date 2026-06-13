import SwiftUI

struct CacheSettingsView: View {
    @ObservedObject private var syncStatus = CloudKitSyncService.shared.status
    @ObservedObject private var dbErrors = DBErrorLog.shared

    @State private var coverCacheBytes = 0

    var body: some View {
        Form {
            Section(String(localized: "cover_cache")) {
                LabeledContent(String(localized: "size"),
                               value: ByteCountFormatter.string(fromByteCount: Int64(coverCacheBytes), countStyle: .file))
                Button(role: .destructive) {
                    Task {
                        await ImageCacheService.shared.clearAll()
                        await refresh()
                    }
                } label: {
                    Text(String(localized: "clear_cache"))
                }
            }

            Section(String(localized: "logs")) {
                NavigationLink(String(localized: "sync_log")) {
                    LogListView(title: String(localized: "sync_log"), entries: syncStatus.logEntries)
                }
                NavigationLink(String(localized: "database_errors")) {
                    LogListView(title: String(localized: "database_errors"), entries: dbErrors.playLogEntries)
                }
            }
        }
        .navigationTitle(String(localized: "cache"))
        .task { await refresh() }
    }

    private func refresh() async {
        coverCacheBytes = await ImageCacheService.shared.diskUsageBytes()
    }
}

/// Generische Log-Anzeige (Snapshot der Einträge).
struct LogListView: View {
    let title: String
    let entries: [String]

    var body: some View {
        Group {
            if entries.isEmpty {
                // .focusable() ist auf tvOS Pflicht: ohne fokussierbares Element fängt der
                // NavigationStack die Menu-Taste nicht als Pop ab → man fliegt aus der App.
                ContentUnavailableView(String(localized: "no_entries"), systemImage: "doc.text")
                    .focusable()
            } else {
                List(Array(entries.enumerated()), id: \.offset) { _, line in
                    // Fokussierbar → Liste wird per Remote scrollbar und Zurück funktioniert.
                    Text(line).font(.caption.monospaced())
                        .focusable()
                }
            }
        }
        .navigationTitle(title)
    }
}
