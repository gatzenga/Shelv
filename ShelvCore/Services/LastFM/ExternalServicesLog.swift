import Combine
import Foundation

/// Short, human readable log of what the external services did: connection
/// checks, approvals and every mix request with its outcome.
@MainActor
final class ExternalServicesLog: ObservableObject {
    static let shared = ExternalServicesLog()

    @Published private(set) var entries: [String] = []

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    nonisolated init() {}

    func clear() { entries.removeAll() }

    nonisolated static func success(_ message: String) { add("✓ " + message) }
    nonisolated static func failure(_ message: String) { add("✗ " + message) }
    nonisolated static func info(_ message: String) { add("• " + message) }

    private nonisolated static func add(_ line: String) {
        print("[ExternalServices] \(line)")
        let date = Date()
        Task { @MainActor in
            let stamp = timeFormatter.string(from: date)
            shared.entries.insert("[\(stamp)] \(line)", at: 0)
            if shared.entries.count > 200 {
                shared.entries.removeLast(shared.entries.count - 200)
            }
        }
    }
}
