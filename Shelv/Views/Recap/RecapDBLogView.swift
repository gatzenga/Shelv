import SwiftUI

struct RecapDBLogView: View {
    @StateObject private var dbLog = DBErrorLog.shared
    @State private var segment: LogTab = .playLog

    enum LogTab: String, CaseIterable {
        case playLog, lyrics
        var label: String {
            switch self {
            case .playLog: return tr("Play Log DB", "Play-Log-DB")
            case .lyrics:  return tr("Lyrics DB", "Lyrics-DB")
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
                    Text(tr("No database errors.", "Keine Datenbank-Fehler."))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(entries, id: \.self) { entry in
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
        .navigationTitle(tr("Database errors", "Datenbank-Fehler"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
