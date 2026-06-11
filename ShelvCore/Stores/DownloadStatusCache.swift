import Foundation
import Combine

@MainActor
final class DownloadStatusCache: ObservableObject {
    static let shared = DownloadStatusCache()

    @Published private(set) var albumIds: Set<String> = []

    private init() {}

    func addAlbum(_ albumId: String) {
        albumIds.insert(albumId)
    }

    func removeAlbum(_ albumId: String) {
        albumIds.remove(albumId)
    }

    func rebuild(albumIds: Set<String>) {
        self.albumIds = albumIds
    }
}
