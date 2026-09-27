import Foundation
import Combine

private nonisolated enum DBLogKind: Sendable {
    case app
    case lyrics
}

private actor DBLogBuffer {
    static let shared = DBLogBuffer()

    private var pendingApp: [String] = []
    private var pendingLyrics: [String] = []
    private var flushTask: Task<Void, Never>?

    func append(_ entry: String, kind: DBLogKind) {
        switch kind {
        case .app: pendingApp.append(entry)
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
        let app = pendingApp
        let lyrics = pendingLyrics
        pendingApp.removeAll(keepingCapacity: true)
        pendingLyrics.removeAll(keepingCapacity: true)
        flushTask = nil
        guard !app.isEmpty || !lyrics.isEmpty else { return }
        await MainActor.run {
            DBErrorLog.shared.apply(app: app, lyrics: lyrics)
        }
    }
}

@MainActor
final class DBErrorLog: ObservableObject {
    static let shared = DBErrorLog()

    @Published var appEntries: [String] = []
    @Published var lyricsEntries: [String] = []

    nonisolated init() {}

    nonisolated static func logDatabase(_ message: String) {
        let stamp = Self.stamp(message)
        Task(priority: .utility) {
            await DBLogBuffer.shared.append(stamp, kind: .app)
        }
        print("[DB:app] \(message)")
    }

    nonisolated static func logLyrics(_ message: String) {
        let stamp = Self.stamp(message)
        Task(priority: .utility) {
            await DBLogBuffer.shared.append(stamp, kind: .lyrics)
        }
        print("[DB:lyrics] \(message)")
    }

    fileprivate func apply(app: [String], lyrics: [String]) {
        if !app.isEmpty {
            appEntries = Array((app.reversed() + appEntries).prefix(200))
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
