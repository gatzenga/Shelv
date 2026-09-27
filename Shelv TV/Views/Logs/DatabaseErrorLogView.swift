import SwiftUI

/// Live database error log that updates as DBErrorLog receives new entries.
struct DatabaseErrorLogView: View {
    @ObservedObject private var dbErrors = DBErrorLog.shared
    @State private var segment: LogTab = .app

    private enum LogTab: String, CaseIterable {
        case app, lyrics

        var title: String {
            switch self {
            case .app: return String(localized: "app_db")
            case .lyrics: return String(localized: "lyrics_db")
            }
        }
    }

    private var entries: [String] {
        switch segment {
        case .app: return dbErrors.appEntries
        case .lyrics: return dbErrors.lyricsEntries
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(LogTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 50)
            .padding(.top, 24)

            LogListView(title: String(localized: "database_errors"), entries: entries)
        }
    }
}
