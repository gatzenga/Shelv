import Foundation

extension Notification.Name {
    static let shelvShortcutDestinationRequested = Notification.Name(
        "shelvShortcutDestinationRequested"
    )
}

enum ShelvShortcutHandoff {
    private static let pendingDestinationKey = "shelv.shortcut.pendingDestination"

    @MainActor
    static func request(_ destination: ShelvShortcutDestination) {
        UserDefaults.standard.set(destination.rawValue, forKey: pendingDestinationKey)
        NotificationCenter.default.post(
            name: .shelvShortcutDestinationRequested,
            object: destination.rawValue
        )
    }

    @MainActor
    static func consumePendingDestination() -> ShelvShortcutDestination? {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingDestinationKey) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: pendingDestinationKey)
        return ShelvShortcutDestination(rawValue: rawValue)
    }
}
