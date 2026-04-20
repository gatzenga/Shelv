import Foundation
import Combine

final class DBErrorLog: ObservableObject {
    static let shared = DBErrorLog()

    @Published var playLogEntries: [String] = []
    @Published var lyricsEntries: [String] = []

    nonisolated init() {}

    nonisolated static func logPlayLog(_ message: String) {
        let stamp = Self.stamp(message)
        Task { @MainActor in
            let entry = stamp
            DBErrorLog.shared.playLogEntries.insert(entry, at: 0)
            if DBErrorLog.shared.playLogEntries.count > 200 {
                DBErrorLog.shared.playLogEntries = Array(DBErrorLog.shared.playLogEntries.prefix(200))
            }
        }
        print("[DB:play_log] \(message)")
    }

    nonisolated static func logLyrics(_ message: String) {
        let stamp = Self.stamp(message)
        Task { @MainActor in
            let entry = stamp
            DBErrorLog.shared.lyricsEntries.insert(entry, at: 0)
            if DBErrorLog.shared.lyricsEntries.count > 200 {
                DBErrorLog.shared.lyricsEntries = Array(DBErrorLog.shared.lyricsEntries.prefix(200))
            }
        }
        print("[DB:lyrics] \(message)")
    }

    private nonisolated static func stamp(_ message: String) -> String {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        return "[\(time)] \(message)"
    }
}
