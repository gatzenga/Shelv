import Foundation

/// Bequeme Cover-URL-Helfer für die Models (tvOS-Views).
private func cover(_ id: String?, _ size: Int) -> URL? {
    guard let id else { return nil }
    return SubsonicAPIService.shared.coverArtURL(for: id, size: size)
}

extension Album    { func coverURL(_ size: Int = 400) -> URL? { cover(coverArt, size) } }
extension Artist   { func coverURL(_ size: Int = 400) -> URL? { cover(coverArt, size) } }
extension Song     { func coverURL(_ size: Int = 400) -> URL? { cover(coverArt, size) } }
extension Playlist { func coverURL(_ size: Int = 400) -> URL? { cover(coverArt, size) } }
