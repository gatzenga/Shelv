import Foundation

nonisolated enum PendingDeletionDisposition: Equatable {
    case completed
    case retry
}

/// Pure helpers for the CloudKit deletion retry queues.
///
/// Shared by every persistent deletion queue, so a failed CloudKit request can
/// be told apart from a record that is already gone.
nonisolated enum CloudKitDeletionLogic {
    /// True when the server said the record is gone for good, rather than
    /// failing for a reason worth retrying.
    static func isDefinitiveNotFound(code: Int, message: String?) -> Bool {
        code == 70
            || (code == 0 && (message ?? "").localizedCaseInsensitiveContains("not found"))
    }

    static func completedDeletionIDs(
        from dispositions: [String: PendingDeletionDisposition]
    ) -> Set<String> {
        Set(dispositions.compactMap { id, disposition in
            disposition == .completed ? id : nil
        })
    }
}
