import CarPlay
import UIKit

// MARK: - Placeholder

let cpPlaceholder: UIImage = {
    let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
    return (UIImage(systemName: "music.note", withConfiguration: cfg) ?? UIImage())
        .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
}()

// MARK: - Image Loading

/// Loads cover art asynchronously; calls `completion` on main actor with the image.
@MainActor
func loadCoverArt(coverArtId: String?, size: Int = 300, completion: @escaping (UIImage) -> Void) {
    guard let id = coverArtId,
          let url = SubsonicAPIService.shared.coverArtURL(for: id, size: size) else { return }
    let key = "\(id)_\(size)"
    if let cached = ImageCacheService.shared.cachedImage(key: key) {
        completion(cached)
        return
    }
    Task {
        guard let img = await ImageCacheService.shared.image(url: url, key: key) else { return }
        completion(img)
    }
}

// MARK: - Handler Typealias

typealias CPItemHandler = (any CPSelectableListItem, @escaping () -> Void) -> Void

// MARK: - CPListItem Factories

func albumListItem(_ album: Album, handler: @escaping CPItemHandler) -> CPListItem {
    let item = CPListItem(text: album.name, detailText: album.artist ?? "")
    item.setImage(cpPlaceholder)
    item.accessoryType = .disclosureIndicator
    item.handler = handler
    return item
}

func artistListItem(_ artist: Artist, subtitle: String, handler: @escaping CPItemHandler) -> CPListItem {
    let item = CPListItem(text: artist.name, detailText: subtitle)
    item.setImage(cpPlaceholder)
    item.accessoryType = .disclosureIndicator
    item.handler = handler
    return item
}

func playlistListItem(_ playlist: Playlist, handler: @escaping CPItemHandler) -> CPListItem {
    let subtitle = playlist.songCount.map { "\($0) \(tr("songs", "Titel"))" } ?? ""
    let item = CPListItem(text: playlist.name, detailText: subtitle)
    item.setImage(cpPlaceholder)
    item.accessoryType = .disclosureIndicator
    item.handler = handler
    return item
}

func songListItem(_ song: Song, index: Int, handler: @escaping CPItemHandler) -> CPListItem {
    let prefix = song.track.map { "\($0). " } ?? ""
    let item = CPListItem(text: "\(prefix)\(song.title)", detailText: song.durationFormatted)
    item.setImage(cpPlaceholder)
    item.handler = handler
    return item
}

func actionListItem(title: String, systemImage: String, handler: @escaping CPItemHandler) -> CPListItem {
    let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
    let icon = (UIImage(systemName: systemImage, withConfiguration: cfg) ?? UIImage())
        .withTintColor(.label, renderingMode: .alwaysOriginal)
    let item = CPListItem(text: title, detailText: nil, image: icon, accessoryImage: nil, accessoryType: .none)
    item.handler = handler
    return item
}

// MARK: - Cover Batch Loader

/// Loads cover art for a set of cover IDs concurrently and returns a dict keyed by cover ID.
@MainActor
func batchLoadCovers(
    _ itemsWithCovers: [(item: CPListItem, coverArtId: String?)],
    size: Int = 300
) async -> [String: UIImage] {
    var result: [String: UIImage] = [:]
    await withTaskGroup(of: (String, UIImage?).self) { group in
        let seen = Set(itemsWithCovers.compactMap { $0.coverArtId })
        for id in seen {
            guard let url = SubsonicAPIService.shared.coverArtURL(for: id, size: size) else { continue }
            let key = "\(id)_\(size)"
            group.addTask { (id, await ImageCacheService.shared.image(url: url, key: key)) }
        }
        for await (id, img) in group { if let img { result[id] = img } }
    }
    return result
}
