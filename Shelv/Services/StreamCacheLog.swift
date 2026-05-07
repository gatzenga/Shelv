import Foundation
import Combine

final class StreamCacheLog: ObservableObject {
    static let shared = StreamCacheLog()

    @Published var entries: [String] = []
    private var titleMap: [String: String] = [:]

    nonisolated init() {}

    nonisolated static func register(songId: String, title: String) {
        Task { @MainActor in
            StreamCacheLog.shared.titleMap[songId] = title
        }
    }

    nonisolated static func log(songId: String, message: String) {
        let stamp = Self.stamp()
        Task { @MainActor in
            let title = StreamCacheLog.shared.titleMap[songId] ?? songId
            StreamCacheLog.shared.entries.insert("[\(stamp)] \(title) – \(message)", at: 0)
            if StreamCacheLog.shared.entries.count > 200 {
                StreamCacheLog.shared.entries = Array(StreamCacheLog.shared.entries.prefix(200))
            }
        }
    }

    func clear() { entries.removeAll() }

    private nonisolated static func stamp() -> String {
        DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    }
}
