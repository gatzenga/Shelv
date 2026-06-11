import SwiftUI

struct RecapDBLogView: View {
    @StateObject private var dbLog = DBErrorLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var segment: LogTab = .playLog

    enum LogTab: String, CaseIterable {
        case playLog, lyrics
        var label: String {
            switch self {
            case .playLog: return String(localized: "play_log_db")
            case .lyrics:  return String(localized: "lyrics_db")
            }
        }
    }

    private var entries: [String] {
        switch segment {
        case .playLog: return dbLog.playLogEntries
        case .lyrics:  return dbLog.lyricsEntries
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(LogTab.allCases, id: \.self) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "no_database_errors"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
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
        .navigationTitle(String(localized: "database_errors"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
        }
    }
}
