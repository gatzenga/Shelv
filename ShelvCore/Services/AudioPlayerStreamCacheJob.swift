import Foundation

struct AudioPlayerStreamCacheJob: Sendable {
    let songId: String
    let title: String
    let url: URL
    let codec: String
    let bitrate: Int
}

struct AudioPlayerStreamCacheWindowPlan: Equatable, Sendable {
    /// Retention follows the logical queue window, while scheduling only contains
    /// jobs that can run under the current connectivity conditions.
    let keepSongIds: Set<String>
    let schedulingSignature: [String]

    init(
        currentSongId: String,
        desiredUpcomingSongIds: [String],
        schedulableJobSongIds: [String]
    ) {
        keepSongIds = Set(desiredUpcomingSongIds).union([currentSongId])
        schedulingSignature = [currentSongId] + schedulableJobSongIds
    }
}
