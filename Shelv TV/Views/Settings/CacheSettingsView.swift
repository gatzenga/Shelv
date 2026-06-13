import SwiftUI

struct CacheSettingsView: View {
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
        }
        .navigationTitle(String(localized: "cache"))
        .task { await refresh() }
    }

    private func refresh() async {
        coverCacheBytes = await ImageCacheService.shared.diskUsageBytes()
    }
}

/// Generische Log-Anzeige (Snapshot der Einträge). Auf tvOS muss jede Zeile fokussierbar
/// sein, sonst lässt sich die Liste weder scrollen noch mit der Menu-Taste verlassen.
struct LogListView: View {
    let title: String
    let entries: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
        .navigationTitle(title)
    }
}

private struct LogRow: View {
    let line: String
    @FocusState private var focused: Bool

    var body: some View {
        Text(line)
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 50)
            .background(focused ? Color.white.opacity(0.12) : Color.clear)
            .focusable()
            .focused($focused)
    }
}
