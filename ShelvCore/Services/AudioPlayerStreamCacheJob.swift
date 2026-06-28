import Foundation

struct AudioPlayerStreamCacheJob: Sendable {
    let songId: String
    let title: String
    let url: URL
    let codec: String
    let bitrate: Int
}
