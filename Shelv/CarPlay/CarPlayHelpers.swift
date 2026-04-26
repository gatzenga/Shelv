import CarPlay
import SwiftUI

// MARK: - Handler Typealias

typealias CPItemHandler = (any CPSelectableListItem, @escaping () -> Void) -> Void

// MARK: - Notifications

extension Notification.Name {
    static let carPlayStarredChanged = Notification.Name("shelv.carPlayStarredChanged")
}

// MARK: - Accent Color

private let cpThemeHexMap: [String: String] = [
    "violet":    "7C3AED",
    "blue":      "0077FF",
    "green":     "00B56A",
    "lightpink": "FF6B9D",
    "lime":      "84CC16",
    "pink":      "FF1988",
    "pumpkin":   "F97316",
    "red":       "DC2626",
    "teal":      "14B8A6",
    "yellow":    "F59E0B",
]

var cpAccentColor: UIColor {
    let name = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
    let hex = cpThemeHexMap[name] ?? "7C3AED"
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    return UIColor(
        red:   CGFloat((int >> 16) & 0xFF) / 255,
        green: CGFloat((int >> 8)  & 0xFF) / 255,
        blue:  CGFloat( int        & 0xFF) / 255,
        alpha: 1
    )
}

// MARK: - Icon Helper

/// Tinted SF-Symbol für CPListItem-Leading-Icons (vertikale Listen).
/// Wird rasterisiert mit eingebrannter Farbe — CarPlay kann die Farbe nicht überschreiben.
func cpIcon(_ systemName: String, pointSize: CGFloat = 22, weight: UIImage.SymbolWeight = .regular, color: UIColor? = nil) -> UIImage {
    let cfg = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    let base = UIImage(systemName: systemName, withConfiguration: cfg) ?? UIImage()
    let tinted = base.withTintColor(color ?? cpAccentColor, renderingMode: .alwaysOriginal)
    let renderer = UIGraphicsImageRenderer(size: tinted.size)
    return renderer.image { _ in tinted.draw(at: .zero) }
}

/// Action-Icon für CPListImageRowItem (horizontale Icon-Reihe).
/// CarPlay resized Bilder dort auf `maximumImageSize` und kann SF-Symbol-Tints überschreiben —
/// deshalb rasterisieren wir das Symbol zentriert auf die erwartete Grösse mit eingebrannter Farbe.
func cpActionIcon(_ systemName: String, color: UIColor? = nil) -> UIImage {
    let renderColor = color ?? cpAccentColor
    let cellSize: CGSize = {
        let s = CPListImageRowItem.maximumImageSize
        return s.width > 0 ? s : CGSize(width: 60, height: 60)
    }()
    let symbolPointSize = floor(cellSize.height * 0.55)
    let cfg = UIImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
    let base = UIImage(systemName: systemName, withConfiguration: cfg) ?? UIImage()
    let tinted = base.withTintColor(renderColor, renderingMode: .alwaysOriginal)
    let renderer = UIGraphicsImageRenderer(size: cellSize)
    return renderer.image { _ in
        let origin = CGPoint(
            x: (cellSize.width  - tinted.size.width)  / 2,
            y: (cellSize.height - tinted.size.height) / 2
        )
        tinted.draw(at: origin)
    }
}

// MARK: - Placeholder

/// Grauer Platzhalter für Album-Art-Slots (via setImage) — 120×120pt mit zentrierter Note.
let cpPlaceholder: UIImage = {
    let size = CGSize(width: 120, height: 120)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
        UIColor.systemGray5.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        let cfg = UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)
            .applying(UIImage.SymbolConfiguration(paletteColors: [UIColor.white.withAlphaComponent(0.45)]))
        if let note = UIImage(systemName: "music.note", withConfiguration: cfg) {
            note.draw(at: CGPoint(
                x: (size.width  - note.size.width)  / 2,
                y: (size.height - note.size.height) / 2
            ))
        }
    }
}()

// MARK: - Image Row Helper

@MainActor
func makeImageRowItem(text: String, images: [UIImage]) -> CPListImageRowItem {
    if #available(iOS 26.0, *) {
        let elements = images.map { CPListImageRowItemGridElement(image: $0) }
        return CPListImageRowItem(text: text, gridElements: elements, allowsMultipleLines: false)
    }
    return CPListImageRowItem(text: text, images: images)
}

// MARK: - Image Loading

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

// MARK: - Article Stripping

func stripArticle(_ title: String) -> String {
    let lower = title.lowercased()
    let prefixes: [String] = [
        "the ", "an ", "a ",
        "der ", "die ", "das ", "dem ", "den ", "des ",
        "eine ", "einer ", "einem ", "einen ", "ein ",
        "les ", "le ", "la ", "l\u{2019}", "l'",
        "une ", "des ", "un ",
        "los ", "las ", "el ", "una ", "un ",
        "gli ", "uno ", "una ", "il ", "lo ",
        "umas ", "uma ", "uns ", "um ", "os ", "as ",
        "het ", "een ", "de ",
    ]
    for p in prefixes where lower.hasPrefix(p) { return String(title.dropFirst(p.count)) }
    return title
}

func firstSortLetter(_ title: String) -> String {
    let key = stripArticle(title)
    let raw = String(key.prefix(1))
    let base = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
    return (base.first?.isLetter == true) ? String(base.prefix(1)) : "#"
}

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

func songListItem(_ song: Song, index: Int, showCover: Bool = false, handler: @escaping CPItemHandler) -> CPListItem {
    let detail: String
    if let artist = song.artist, !artist.isEmpty {
        let dur = song.durationFormatted
        detail = dur.isEmpty ? artist : "\(artist) · \(dur)"
    } else {
        detail = song.durationFormatted
    }
    let item = CPListItem(text: song.title, detailText: detail)
    if showCover { item.setImage(cpPlaceholder) }
    item.handler = handler
    return item
}

func actionListItem(title: String, systemImage: String, handler: @escaping CPItemHandler) -> CPListItem {
    let item = CPListItem(text: title, detailText: nil, image: cpIcon(systemImage, pointSize: 22), accessoryImage: nil, accessoryType: .none)
    item.handler = handler
    return item
}

func menuListItem(title: String, systemImage: String, handler: @escaping CPItemHandler) -> CPListItem {
    let item = CPListItem(text: title, detailText: nil, image: cpIcon(systemImage, pointSize: 20), accessoryImage: nil, accessoryType: .disclosureIndicator)
    item.handler = handler
    return item
}

func showAllListItem(title: String, handler: @escaping CPItemHandler) -> CPListItem {
    let item = CPListItem(text: title, detailText: nil, image: cpIcon("chevron.right.circle", pointSize: 20), accessoryImage: nil, accessoryType: .none)
    item.handler = handler
    return item
}

// MARK: - Cover Batch Loader

/// Streamt Cover-Loads in Chunks und ruft `onChunk` nach jedem fertigen Chunk auf —
/// die UI kann dadurch sichtbar nachfüllen statt erst am Ende zu blocken.
///
/// Reihenfolge der Quellen pro ID:
/// 1. Memory-Cache (synchron, sofort)
/// 2. Offline: `LocalArtworkIndex` (heruntergeladene Artwork-Pfade)
/// 3. Offline: Disk-Cache mit Multi-Size-Fallback `[size, 150, 300, 600]`
/// 4. Online: Disk → Network via `ImageCacheService`
@MainActor
func loadCoversIncremental(
    coverArtIds ids: [String?],
    size: Int = 300,
    chunkSize: Int = 20,
    onChunk: @escaping ([String: UIImage]) -> Void
) async {
    let unique = Array(Set(ids.compactMap { $0 }))
    guard !unique.isEmpty else { return }

    let isOffline = OfflineModeService.shared.isOffline
    let sizeFallback = [size, 150, 300, 600]

    // 1) Memory-Cache synchron abfragen (immer Main Actor, In-Memory)
    var syncHits: [String: UIImage] = [:]
    var misses: [String] = []
    for id in unique {
        if let img = firstMemoryHit(id: id, sizes: sizeFallback) {
            syncHits[id] = img
        } else {
            misses.append(id)
        }
    }

    // 2) Offline: LocalArtworkIndex-Pfade auf Main Actor sammeln, UIImage-Reads in Background (FIX 7)
    if isOffline && !misses.isEmpty {
        let pathsById: [String: String] = misses.reduce(into: [:]) { dict, id in
            if let path = LocalArtworkIndex.shared.localPath(for: id) { dict[id] = path }
        }
        if !pathsById.isEmpty {
            let offlineHits = await Task.detached(priority: .userInitiated) {
                var hits: [String: UIImage] = [:]
                for (id, path) in pathsById {
                    if let img = UIImage(contentsOfFile: path) { hits[id] = img }
                }
                return hits
            }.value
            syncHits.merge(offlineHits) { _, new in new }
            misses = misses.filter { syncHits[$0] == nil }
        }
    }

    if Task.isCancelled { return }
    if !syncHits.isEmpty { onChunk(syncHits) }
    guard !misses.isEmpty else { return }

    // 3) Async-Misses in Chunks laden — UI nach jedem Chunk updaten.
    let chunks = stride(from: 0, to: misses.count, by: chunkSize).map {
        Array(misses[$0..<min($0 + chunkSize, misses.count)])
    }
    for chunk in chunks {
        if Task.isCancelled { return }
        var chunkResult: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for id in chunk {
                if isOffline {
                    group.addTask {
                        // Disk-Cache Multi-Size-Fallback (Cover wurde mal vom iPhone gerendert).
                        for s in sizeFallback {
                            if let img = await ImageCacheService.shared.diskOnlyImage(key: "\(id)_\(s)") {
                                return (id, img)
                            }
                        }
                        return (id, nil)
                    }
                } else {
                    guard let url = SubsonicAPIService.shared.coverArtURL(for: id, size: size) else { continue }
                    let key = "\(id)_\(size)"
                    group.addTask { (id, await ImageCacheService.shared.image(url: url, key: key)) }
                }
            }
            for await (id, img) in group { if let img { chunkResult[id] = img } }
        }
        if !chunkResult.isEmpty { onChunk(chunkResult) }
    }
}

private func firstMemoryHit(id: String, sizes: [Int]) -> UIImage? {
    for s in sizes {
        if let img = ImageCacheService.shared.cachedImage(key: "\(id)_\(s)") {
            return img
        }
    }
    return nil
}

/// Streamt Covers für eine Liste in `template` — Sections werden via `rebuild` neu erzeugt
/// und nach jedem Cover-Chunk angewendet. Akkumuliert die Image-Map über alle Chunks.
///
/// Aufrufer übergibt einen `rebuild`-Closure der aus dem aktuellen Image-Map die Sections
/// zurückgibt. Dadurch füllt sich die Liste sichtbar — kein Wait auf alle Covers.
@MainActor
func applyCoversAsync(
    template: CPListTemplate,
    coverArtIds ids: [String?],
    size: Int = 300,
    chunkSize: Int = 20,
    rebuild: @escaping ([String: UIImage]) -> [CPListSection]
) async {
    var accumulated: [String: UIImage] = [:]
    await loadCoversIncremental(coverArtIds: ids, size: size, chunkSize: chunkSize) { chunk in
        // FIX 10: accumulated auf max 150 Einträge begrenzen — sonst Speicherdruck bei 500+ Songs
        for (key, img) in chunk {
            if accumulated.count >= 150, let oldest = accumulated.keys.first {
                accumulated.removeValue(forKey: oldest)
            }
            accumulated[key] = img
        }
        template.updateSections(rebuild(accumulated))
    }
}

/// Bulk-Variante für Aufrufer, die einen kompletten Map am Ende benötigen.
/// Intern via `loadCoversIncremental` — kein Chunk-Streaming, einmaliger Return.
@MainActor
func batchLoadCovers(
    _ itemsWithCovers: [(item: CPListItem, coverArtId: String?)],
    size: Int = 300
) async -> [String: UIImage] {
    var result: [String: UIImage] = [:]
    let ids = itemsWithCovers.map { $0.coverArtId }
    await loadCoversIncremental(coverArtIds: ids, size: size, chunkSize: 20) { chunk in
        result.merge(chunk) { _, new in new }
    }
    return result
}
