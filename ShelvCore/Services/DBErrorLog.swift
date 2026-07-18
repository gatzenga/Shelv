import Foundation
import Combine

private nonisolated enum DBLogKind: Sendable {
    case playLog
    case lyrics
}

private actor DBLogBuffer {
    static let shared = DBLogBuffer()

    private var pendingPlayLog: [String] = []
    private var pendingLyrics: [String] = []
    private var flushTask: Task<Void, Never>?

    func append(_ entry: String, kind: DBLogKind) {
        switch kind {
        case .playLog: pendingPlayLog.append(entry)
        case .lyrics: pendingLyrics.append(entry)
        }
        guard flushTask == nil else { return }
        flushTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    private func flush() async {
        let playLog = pendingPlayLog
        let lyrics = pendingLyrics
        pendingPlayLog.removeAll(keepingCapacity: true)
        pendingLyrics.removeAll(keepingCapacity: true)
        flushTask = nil
        guard !playLog.isEmpty || !lyrics.isEmpty else { return }
        await MainActor.run {
            DBErrorLog.shared.apply(playLog: playLog, lyrics: lyrics)
        }
    }
}

@MainActor
final class DBErrorLog: ObservableObject {
    static let shared = DBErrorLog()

    @Published var playLogEntries: [String] = []
    @Published var lyricsEntries: [String] = []

    nonisolated init() {}

    nonisolated static func logPlayLog(_ message: String) {
        let stamp = Self.stamp(message)
        Task(priority: .utility) {
            await DBLogBuffer.shared.append(stamp, kind: .playLog)
        }
        print("[DB:play_log] \(message)")
    }

    nonisolated static func logLyrics(_ message: String) {
        let stamp = Self.stamp(message)
        Task(priority: .utility) {
            await DBLogBuffer.shared.append(stamp, kind: .lyrics)
        }
        print("[DB:lyrics] \(message)")
    }

    fileprivate func apply(playLog: [String], lyrics: [String]) {
        if !playLog.isEmpty {
            playLogEntries = Array((playLog.reversed() + playLogEntries).prefix(200))
        }
        if !lyrics.isEmpty {
            lyricsEntries = Array((lyrics.reversed() + lyricsEntries).prefix(200))
        }
    }

    private nonisolated static func stamp(_ message: String) -> String {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        return "[\(time)] \(message)"
    }
}
