import SwiftUI

struct RecapDBLogView: View {
    @StateObject private var dbLog = DBErrorLog.shared
    @State private var segment: LogTab = .playLog

    enum LogTab: String, CaseIterable {
        case playLog, lyrics
        var label: String {
            switch self {
            case .playLog: return tr("recap.recap.db.log.play_log_db")
            case .lyrics:  return tr("recap.recap.db.log.lyrics_db")
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
            .padding(.horizontal)
            .padding(.vertical, 12)

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(tr("recap.recap.db.log.no_database_errors"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
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
        .navigationTitle(tr("recap.recap.db.log.database_errors"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
