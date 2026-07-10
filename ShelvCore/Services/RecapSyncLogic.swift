import Foundation

nonisolated enum RecapSyncLogicError: LocalizedError, Equatable {
    case deadSongCleanupFailed

    var errorDescription: String? {
        String(localized: "server_returned_an_error")
    }
}

nonisolated struct RecapPlaylistMutationPlan: Equatable {
    let songIdsToAdd: [String]
    let songIndicesToRemove: [Int]

    init?(currentIds: [String], expectedIds: [String]) {
        guard currentIds != expectedIds else { return nil }
        songIdsToAdd = expectedIds
        songIndicesToRemove = Array(currentIds.indices)
    }
}

nonisolated enum PendingDeletionDisposition: Equatable {
    case completed
    case retry
}

nonisolated enum RecapSyncLogic {
    static func stabilized<Result>(
        scan: () async throws -> (result: Result, deadSongIds: Set<String>),
        removeDeadSongIds: ([String]) async -> Int
    ) async throws -> Result {
        var attemptedDeadSongIds: Set<String> = []

        while true {
            let scanResult = try await scan()
            guard !scanResult.deadSongIds.isEmpty else { return scanResult.result }

            let newlyDead = scanResult.deadSongIds.subtracting(attemptedDeadSongIds)
            guard !newlyDead.isEmpty else {
                throw RecapSyncLogicError.deadSongCleanupFailed
            }

            attemptedDeadSongIds.formUnion(newlyDead)
            _ = await removeDeadSongIds(newlyDead.sorted())
        }
    }

    static func isDefinitiveNotFound(code: Int, message: String?) -> Bool {
        code == 70
            || (code == 0 && (message ?? "").localizedCaseInsensitiveContains("not found"))
    }

    static func playlistMatches(
        ids: [String],
        name: String,
        comment: String?,
        expectedIds: [String],
        expectedName: String
    ) -> Bool {
        ids == expectedIds
            && name == expectedName
            && (comment ?? "") == "Shelv Recap"
    }

    static func completedDeletionIDs(
        from dispositions: [String: PendingDeletionDisposition]
    ) -> Set<String> {
        Set(dispositions.compactMap { id, disposition in
            disposition == .completed ? id : nil
        })
    }
}
