import SwiftUI

struct CacheSettingsView: View {
    @AppStorage("streamPreCacheEnabled") private var streamPreCacheEnabled = false
    @State private var coverCacheBytes = 0

    var body: some View {
        Form {
            Text(String(localized: "cache"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            // Precache wie iOS/macOS — Logik liegt im geteilten AudioPlayerService/StreamCacheService.
            Section(String(localized: "precache")) {
                Toggle(String(localized: "precache_original_file"), isOn: $streamPreCacheEnabled)
                NavigationLink {
                    ScrollView {
                        Text(String(localized: "stable_networkindependent_playback_with_seamless_g"))
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(60)
                            .focusable()
                    }
                    .navigationTitle(String(localized: "precache"))
                    .toolbar(.hidden, for: .tabBar)
                } label: {
                    Text(String(localized: "about_precache"))
                }
                NavigationLink {
                    CacheLogView()
                } label: {
                    Text(String(localized: "logs"))
                }
            }

            Section(String(localized: "cover_cache")) {
                LabeledContent(String(localized: "size"),
                               value: ByteCountFormatter.string(fromByteCount: Int64(coverCacheBytes), countStyle: .file))
                DestructiveButton(title: String(localized: "clear_cache"), systemImage: "trash") {
                    Task {
                        await ImageCacheService.shared.clearAll()
                        await refresh()
                    }
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .task { await refresh() }
    }

    private func refresh() async {
        coverCacheBytes = await ImageCacheService.shared.diskUsageBytes()
    }
}

/// Live Cache-Log — beobachtet StreamCacheLog und reicht die aktuellen Einträge an die
/// generische LogListView weiter, sodass neue Precache-Events sofort erscheinen (kein Snapshot).
struct CacheLogView: View {
    @ObservedObject private var log = StreamCacheLog.shared

    var body: some View {
        LogListView(title: String(localized: "cache_log"), entries: log.entries)
    }
}

/// Generische Log-Anzeige (Snapshot der Einträge). Auf tvOS muss jede Zeile fokussierbar
/// sein, sonst lässt sich die Liste weder scrollen noch mit der Menu-Taste verlassen.
struct LogListView: View {
    let title: String
    let entries: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.largeTitle).bold()
                    .padding(.horizontal, 50)
                    .padding(.bottom, 16)
                ForEach(Array(entries.enumerated()), id: \.offset) { _, line in
                    LogRow(line: line)
                }
            }
            .padding(.vertical, 24)
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(String(localized: "no_entries"), systemImage: "doc.text")
                    .focusable()
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

private struct LogRow: View {
    let line: String
    @FocusState private var focused: Bool
    @AppStorage("themeColor") private var themeColor = "violet"

    var body: some View {
        Text(line)
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 24)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(focused ? AppTheme.color(for: themeColor).opacity(0.4) : .clear))
            .padding(.horizontal, 38)
            .focusable()
            .focused($focused)
    }
}
