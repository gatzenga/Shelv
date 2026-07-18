import Foundation
import Combine

@MainActor
final class DownloadStatusCache: ObservableObject {
    static let shared = DownloadStatusCache()

    @Published private(set) var albumIds: Set<String> = []

    private init() {}

    func addAlbum(_ albumId: String) {
        guard !albumIds.contains(albumId) else { return }
        albumIds.insert(albumId)
    }

    func removeAlbum(_ albumId: String) {
        guard albumIds.contains(albumId) else { return }
        albumIds.remove(albumId)
    }

    func rebuild(albumIds: Set<String>) {
        guard self.albumIds != albumIds else { return }
        self.albumIds = albumIds
    }
}
