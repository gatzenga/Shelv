import Foundation

/// Compatibility adapter for the original iOS App Intents dependency.
/// All platforms and the iOS/macOS audio schema now share one executor so
/// cancellation, offline fallbacks, queue handling and diagnostics agree.
@MainActor
final class ShortcutPlaybackCoordinator: @unchecked Sendable {
    static let shared = ShortcutPlaybackCoordinator()

    private init() {}

    func execute(_ command: ShortcutPlaybackCommand) async throws {
        try await ShelvSystemIntentPlaybackService.shared.execute(command)
    }
}
