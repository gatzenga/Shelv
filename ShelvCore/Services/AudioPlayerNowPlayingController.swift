import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if os(macOS)
private typealias PlatformArtworkImage = NSImage
#else
private typealias PlatformArtworkImage = UIImage
#endif

private struct RadioArtworkSource: Sendable {
    let url: URL
    let cacheKeys: [String]
    let coverArtID: String?

    var identifier: String { url.absoluteString }
}

final class AudioPlayerNowPlayingController {
    private var currentArtwork: MPMediaItemArtwork?
    private var currentArtworkSource: String?
    private var currentArtworkIsFallback = false
    private var loadingArtworkSource: String?
    private var artworkTask: Task<Void, Never>?
    private var lastReportedTime: Double = -1
    nonisolated(unsafe) private static let nowPlayingArtworkCache: NSCache<NSString, MPMediaItemArtwork> = {
        let cache = NSCache<NSString, MPMediaItemArtwork>()
        cache.countLimit = 80
        return cache
    }()
    private static let nowPlayingArtworkSize = 600
    private var prewarmArtworkTask: Task<Void, Never>?

    func update(song: Song, currentTime: Double) {
        cancelArtwork()
        currentArtwork = nil
        currentArtworkSource = nil
        currentArtworkIsFallback = false
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue as NSNumber
        if let d = song.duration { info[MPMediaItemPropertyPlaybackDuration] = Double(d) }

        if let artId = song.coverArt,
           let artURL = SubsonicAPIService.shared.coverArtURL(for: artId, size: 600) {
            #if os(iOS)
            let source = Self.songArtworkSource(for: artId)
            let cached = Self.cachedSongArtwork(for: artId, preferredSize: Self.nowPlayingArtworkSize)
            if let cached {
                currentArtwork = cached.artwork
                currentArtworkSource = source
                currentArtworkIsFallback = cached.isFallback
                info[MPMediaItemPropertyArtwork] = cached.artwork
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            if cached == nil || cached?.isFallback == true {
                loadSongArtworkIfNeeded(artId: artId, artURL: artURL, source: source)
            }
            return
            #elseif os(macOS)
            let source = Self.songArtworkSource(for: artId)
            let cached = Self.cachedSongArtwork(for: artURL)
            if let cached {
                currentArtwork = cached.artwork
                currentArtworkSource = source
                currentArtworkIsFallback = cached.isFallback
                info[MPMediaItemPropertyArtwork] = cached.artwork
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            if cached == nil || cached?.isFallback == true {
                loadSongArtworkIfNeeded(artId: artId, artURL: artURL, source: source)
            }
            return
            #else
            let source = Self.songArtworkSource(for: artId)
            let cached = Self.cachedSongArtwork(for: artURL)
            if let cached {
                currentArtwork = cached.artwork
                currentArtworkSource = source
                currentArtworkIsFallback = cached.isFallback
                info[MPMediaItemPropertyArtwork] = cached.artwork
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            if cached == nil || cached?.isFallback == true {
                loadSongArtworkIfNeeded(artId: artId, artURL: artURL, source: source)
            }
            return
            #endif
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    #if os(iOS)
    func primeSong(song: Song, currentTime: Double) {
        cancelArtwork()
        currentArtwork = nil
        currentArtworkSource = nil
        currentArtworkIsFallback = false

        var info = Self.baseSongInfo(for: song, currentTime: currentTime)
        guard let artId = song.coverArt else {
            Self.debugArtwork("prime miss: no cover id")
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }

        let source = Self.songArtworkSource(for: artId)
        currentArtworkSource = source
        let cached = Self.cachedSongArtwork(for: artId, preferredSize: Self.nowPlayingArtworkSize)
        if let cached {
            currentArtwork = cached.artwork
            currentArtworkIsFallback = cached.isFallback
            info[MPMediaItemPropertyArtwork] = cached.artwork
            Self.debugArtwork(cached.isFallback ? "prime memory fallback" : "prime memory exact")
        } else {
            Self.debugArtwork("prime memory miss")
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard cached == nil || cached?.isFallback == true else { return }
        let preferredKey = "\(artId)_\(Self.nowPlayingArtworkSize)"
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: Self.nowPlayingArtworkSize)
        Task(priority: .userInitiated) { [weak self] in
            if let localPath = LocalArtworkIndex.shared.localPath(for: artId) {
                let image = await Task.detached(priority: .userInitiated) {
                    UIImage(contentsOfFile: localPath)
                }.value
                if let image, !Task.isCancelled {
                    ImageCacheService.shared.cache(image, key: preferredKey)
                    let artwork = Self.nowPlayingArtwork(for: image, cacheKey: Self.songArtworkCacheKey(for: preferredKey))
                    Self.debugArtwork("prime local file")
                    self?.applySongArtwork(artwork, source: source, isFallback: false, finishLoading: false)
                    return
                }
            }

            if let cached = await ImageCacheService.shared.diskOnlyImageResult(key: preferredKey, fallbackSizes: fallbackSizes),
               !Task.isCancelled {
                let artwork = Self.nowPlayingArtwork(for: cached.image, cacheKey: Self.songArtworkCacheKey(for: cached.key))
                Self.debugArtwork(cached.key == preferredKey ? "prime disk exact" : "prime disk fallback")
                self?.applySongArtwork(
                    artwork,
                    source: source,
                    isFallback: cached.key != preferredKey,
                    finishLoading: false
                )
            }
        }
    }

    func prewarmSongArtwork(for songs: [Song], limit: Int = 5) {
        let artIds = Self.uniqueArtworkIDs(from: songs, limit: limit)
        guard !artIds.isEmpty else { return }

        prewarmArtworkTask?.cancel()
        prewarmArtworkTask = Task(priority: .utility) {
            let isOffline = UserDefaults.standard.bool(forKey: "offlineModeEnabled")
            for artId in artIds {
                guard !Task.isCancelled else { return }
                await Self.prewarmSongArtwork(artId: artId, isOffline: isOffline)
            }
        }
    }

    private func loadSongArtworkIfNeeded(artId: String, artURL: URL, source: String) {
        guard source != loadingArtworkSource else { return }
        loadingArtworkSource = source
        let preferredSize = Self.nowPlayingArtworkSize
        let preferredKey = "\(artId)_\(preferredSize)"
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: preferredSize)
        let isOffline = UserDefaults.standard.bool(forKey: "offlineModeEnabled")

        artworkTask = Task(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            if let localPath = LocalArtworkIndex.shared.localPath(for: artId) {
                let image = await Task.detached(priority: .userInitiated) {
                    UIImage(contentsOfFile: localPath)
                }.value
                if let image, !Task.isCancelled {
                    ImageCacheService.shared.cache(image, key: preferredKey)
                    let artwork = Self.nowPlayingArtwork(for: image, cacheKey: Self.songArtworkCacheKey(for: preferredKey))
                    Self.debugArtwork("load local file")
                    self?.applySongArtwork(artwork, source: source, isFallback: false, finishLoading: true)
                    return
                }
            }

            if let cached = await ImageCacheService.shared.diskOnlyImageResult(key: preferredKey, fallbackSizes: fallbackSizes),
               !Task.isCancelled {
                let isFallback = cached.key != preferredKey
                let artwork = Self.nowPlayingArtwork(for: cached.image, cacheKey: Self.songArtworkCacheKey(for: cached.key))
                Self.debugArtwork(isFallback ? "load disk fallback" : "load disk exact")
                self?.applySongArtwork(
                    artwork,
                    source: source,
                    isFallback: isFallback,
                    finishLoading: !isFallback || isOffline
                )
                if !isFallback || isOffline { return }
            }

            guard !isOffline else {
                self?.finishSongArtworkLoad(source: source)
                return
            }

            for attempt in 1...3 {
                if Task.isCancelled { return }
                if let image = await ImageCacheService.shared.image(url: artURL, key: preferredKey) {
                    let artwork = Self.nowPlayingArtwork(for: image, cacheKey: Self.songArtworkCacheKey(for: preferredKey))
                    Self.debugArtwork("load network exact")
                    self?.applySongArtwork(artwork, source: source, isFallback: false, finishLoading: true)
                    return
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(300 * attempt))
                }
            }

            self?.finishSongArtworkLoad(source: source)
            Self.debugArtwork("load failed")
        }
    }

    @MainActor
    private func applySongArtwork(
        _ artwork: MPMediaItemArtwork,
        source: String,
        isFallback: Bool,
        finishLoading: Bool
    ) {
        guard loadingArtworkSource == source || currentArtworkSource == source else { return }
        if isFallback,
           currentArtworkSource == source,
           currentArtwork != nil,
           !currentArtworkIsFallback {
            return
        }
        currentArtwork = artwork
        currentArtworkSource = source
        currentArtworkIsFallback = isFallback
        if finishLoading, loadingArtworkSource == source {
            loadingArtworkSource = nil
        }
        var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        updated[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
    }

    @MainActor
    private func finishSongArtworkLoad(source: String) {
        guard loadingArtworkSource == source else { return }
        loadingArtworkSource = nil
    }

    private static func cachedSongArtwork(
        for artId: String,
        preferredSize: Int
    ) -> (artwork: MPMediaItemArtwork, isFallback: Bool)? {
        let preferredKey = "\(artId)_\(preferredSize)"
        for size in ImageCacheService.coverFallbackSizes(preferred: preferredSize) {
            let imageKey = "\(artId)_\(size)"
            let artworkKey = songArtworkCacheKey(for: imageKey)
            if let artwork = nowPlayingArtworkCache.object(forKey: artworkKey as NSString) {
                return (artwork, imageKey != preferredKey)
            }
            guard let image = ImageCacheService.shared.cachedImage(key: imageKey) else { continue }
            return (nowPlayingArtwork(for: image, cacheKey: artworkKey), imageKey != preferredKey)
        }
        return nil
    }

    private static func prewarmSongArtwork(artId: String, isOffline: Bool) async {
        let preferredSize = nowPlayingArtworkSize
        let preferredKey = "\(artId)_\(preferredSize)"
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: preferredSize)

        if let cached = cachedSongArtwork(for: artId, preferredSize: preferredSize),
           !cached.isFallback {
            return
        }

        if let localPath = LocalArtworkIndex.shared.localPath(for: artId) {
            let image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: localPath)
            }.value
            if let image, !Task.isCancelled {
                ImageCacheService.shared.cache(image, key: preferredKey)
                _ = nowPlayingArtwork(for: image, cacheKey: songArtworkCacheKey(for: preferredKey))
                return
            }
        }

        if let cached = await ImageCacheService.shared.diskOnlyImageResult(key: preferredKey, fallbackSizes: fallbackSizes),
           !Task.isCancelled {
            _ = nowPlayingArtwork(for: cached.image, cacheKey: songArtworkCacheKey(for: cached.key))
            if cached.key == preferredKey || isOffline {
                return
            }
        }

        guard !isOffline,
              let artURL = SubsonicAPIService.shared.coverArtURL(for: artId, size: preferredSize)
        else { return }

        if let image = await ImageCacheService.shared.image(url: artURL, key: preferredKey),
           !Task.isCancelled {
            _ = nowPlayingArtwork(for: image, cacheKey: songArtworkCacheKey(for: preferredKey))
        }
    }

    private static func nowPlayingArtwork(for image: UIImage, cacheKey: String) -> MPMediaItemArtwork {
        if let cached = nowPlayingArtworkCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        let square = squareCroppedArtworkImage(image)
        let artwork = MPMediaItemArtwork(boundsSize: square.size) { _ in square }
        nowPlayingArtworkCache.setObject(artwork, forKey: cacheKey as NSString)
        return artwork
    }

    private static func songArtworkSource(for artId: String) -> String {
        "song:\(artId)"
    }

    private static func songArtworkCacheKey(for imageCacheKey: String) -> String {
        "nowplaying:\(imageCacheKey)"
    }

    private static func baseSongInfo(for song: Song, currentTime: Double) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue as NSNumber
        if let d = song.duration { info[MPMediaItemPropertyPlaybackDuration] = Double(d) }
        return info
    }

    private static func debugArtwork(_ message: String) {
        #if DEBUG
        print("[ArtworkCache] \(message)")
        #endif
    }

    private static func uniqueArtworkIDs(from songs: [Song], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for song in songs {
            guard let artId = song.coverArt,
                  !artId.isEmpty,
                  seen.insert(artId).inserted
            else { continue }
            result.append(artId)
            if result.count == limit { break }
        }
        return result
    }
    #endif

    #if !os(iOS)
    func primeSong(song: Song, currentTime: Double) {
        cancelArtwork()
        currentArtwork = nil
        currentArtworkSource = nil
        currentArtworkIsFallback = false

        var info = Self.baseSongInfo(for: song, currentTime: currentTime)
        guard let artId = song.coverArt,
              let artURL = SubsonicAPIService.shared.coverArtURL(for: artId, size: Self.nowPlayingArtworkSize)
        else {
            Self.debugArtwork("prime miss: no cover url")
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }

        let source = Self.songArtworkSource(for: artId)
        currentArtworkSource = source
        let cached = Self.cachedSongArtwork(for: artURL)
        if let cached {
            currentArtwork = cached.artwork
            currentArtworkIsFallback = cached.isFallback
            info[MPMediaItemPropertyArtwork] = cached.artwork
            Self.debugArtwork(cached.isFallback ? "prime memory fallback" : "prime memory exact")
        } else {
            Self.debugArtwork("prime memory miss")
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard cached == nil || cached?.isFallback == true else { return }
        let exactKey = ImageCacheService.stableCacheKey(for: artURL)
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: Self.nowPlayingArtworkSize)
        Task(priority: .userInitiated) { [weak self] in
            if let image = await Self.localSongArtworkImage(artId: artId) {
                ImageCacheService.shared.cache(image, url: artURL)
                let artwork = Self.nowPlayingArtwork(for: image, cacheKey: Self.songArtworkCacheKey(for: exactKey))
                Self.debugArtwork("prime local file")
                self?.applySongArtwork(artwork, source: source, isFallback: false, finishLoading: false)
                return
            }

            if let cached = await ImageCacheService.shared.diskOnlyImageResult(url: artURL, fallbackSizes: fallbackSizes),
               !Task.isCancelled {
                let artwork = Self.nowPlayingArtwork(for: cached.image, cacheKey: Self.songArtworkCacheKey(for: cached.key))
                Self.debugArtwork(cached.key == exactKey ? "prime disk exact" : "prime disk fallback")
                self?.applySongArtwork(
                    artwork,
                    source: source,
                    isFallback: cached.key != exactKey,
                    finishLoading: false
                )
            }
        }
    }

    func prewarmSongArtwork(for songs: [Song], limit: Int = 5) {
        let artIds = Self.uniqueArtworkIDs(from: songs, limit: limit)
        guard !artIds.isEmpty else { return }

        prewarmArtworkTask?.cancel()
        prewarmArtworkTask = Task(priority: .utility) {
            let isOffline = UserDefaults.standard.bool(forKey: "offlineModeEnabled")
            for artId in artIds {
                guard !Task.isCancelled else { return }
                await Self.prewarmSongArtwork(artId: artId, isOffline: isOffline)
            }
        }
    }

    private func loadSongArtworkIfNeeded(artId: String, artURL: URL, source: String) {
        guard source != loadingArtworkSource else { return }
        loadingArtworkSource = source
        let exactKey = ImageCacheService.stableCacheKey(for: artURL)
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: Self.nowPlayingArtworkSize)
        let isOffline = UserDefaults.standard.bool(forKey: "offlineModeEnabled")

        artworkTask = Task(priority: .userInitiated) { [weak self] in
            if let image = await Self.localSongArtworkImage(artId: artId) {
                ImageCacheService.shared.cache(image, url: artURL)
                let artwork = Self.nowPlayingArtwork(for: image, cacheKey: Self.songArtworkCacheKey(for: exactKey))
                Self.debugArtwork("load local file")
                self?.applySongArtwork(artwork, source: source, isFallback: false, finishLoading: true)
                return
            }

            if let cached = await ImageCacheService.shared.diskOnlyImageResult(url: artURL, fallbackSizes: fallbackSizes),
               !Task.isCancelled {
                let isFallback = cached.key != exactKey
                let artwork = Self.nowPlayingArtwork(for: cached.image, cacheKey: Self.songArtworkCacheKey(for: cached.key))
                Self.debugArtwork(isFallback ? "load disk fallback" : "load disk exact")
                self?.applySongArtwork(
                    artwork,
                    source: source,
                    isFallback: isFallback,
                    finishLoading: !isFallback || isOffline
                )
                if !isFallback || isOffline { return }
            }

            guard !isOffline else {
                self?.finishSongArtworkLoad(source: source)
                return
            }

            if let image = await ImageCacheService.shared.image(url: artURL),
               !Task.isCancelled {
                let artwork = Self.nowPlayingArtwork(for: image, cacheKey: Self.songArtworkCacheKey(for: exactKey))
                Self.debugArtwork("load network exact")
                self?.applySongArtwork(artwork, source: source, isFallback: false, finishLoading: true)
                return
            }

            self?.finishSongArtworkLoad(source: source)
            Self.debugArtwork("load failed")
        }
    }

    @MainActor
    private func applySongArtwork(
        _ artwork: MPMediaItemArtwork,
        source: String,
        isFallback: Bool,
        finishLoading: Bool
    ) {
        guard loadingArtworkSource == source || currentArtworkSource == source else { return }
        if isFallback,
           currentArtworkSource == source,
           currentArtwork != nil,
           !currentArtworkIsFallback {
            return
        }
        currentArtwork = artwork
        currentArtworkSource = source
        currentArtworkIsFallback = isFallback
        if finishLoading, loadingArtworkSource == source {
            loadingArtworkSource = nil
        }
        var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        updated[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
    }

    @MainActor
    private func finishSongArtworkLoad(source: String) {
        guard loadingArtworkSource == source else { return }
        loadingArtworkSource = nil
    }

    private static func cachedSongArtwork(for artURL: URL) -> (artwork: MPMediaItemArtwork, isFallback: Bool)? {
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: nowPlayingArtworkSize)
        guard let cached = ImageCacheService.shared.cachedImage(url: artURL, fallbackSizes: fallbackSizes) else {
            return nil
        }
        let exactKey = ImageCacheService.stableCacheKey(for: artURL)
        let artworkKey = songArtworkCacheKey(for: cached.key)
        return (nowPlayingArtwork(for: cached.image, cacheKey: artworkKey), cached.key != exactKey)
    }

    private static func prewarmSongArtwork(artId: String, isOffline: Bool) async {
        guard let artURL = SubsonicAPIService.shared.coverArtURL(for: artId, size: nowPlayingArtworkSize) else {
            return
        }
        let exactKey = ImageCacheService.stableCacheKey(for: artURL)
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: nowPlayingArtworkSize)

        if let cached = cachedSongArtwork(for: artURL),
           !cached.isFallback {
            return
        }

        if let image = await localSongArtworkImage(artId: artId) {
            ImageCacheService.shared.cache(image, url: artURL)
            _ = nowPlayingArtwork(for: image, cacheKey: songArtworkCacheKey(for: exactKey))
            return
        }

        if let cached = await ImageCacheService.shared.diskOnlyImageResult(url: artURL, fallbackSizes: fallbackSizes),
           !Task.isCancelled {
            _ = nowPlayingArtwork(for: cached.image, cacheKey: songArtworkCacheKey(for: cached.key))
            if cached.key == exactKey || isOffline {
                return
            }
        }

        guard !isOffline else { return }
        if let image = await ImageCacheService.shared.image(url: artURL),
           !Task.isCancelled {
            _ = nowPlayingArtwork(for: image, cacheKey: songArtworkCacheKey(for: exactKey))
        }
    }

    private static func localSongArtworkImage(artId: String) async -> PlatformArtworkImage? {
        guard let localPath = LocalArtworkIndex.shared.localPath(for: artId) else { return nil }
        return await Task.detached(priority: .utility) {
            #if os(macOS)
            NSImage(contentsOfFile: localPath)
            #else
            UIImage(contentsOfFile: localPath)
            #endif
        }.value
    }

    private static func nowPlayingArtwork(for image: PlatformArtworkImage, cacheKey: String) -> MPMediaItemArtwork {
        if let cached = nowPlayingArtworkCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        #if os(macOS)
        let artwork = MPMediaItemArtwork(
            boundsSize: CGSize(width: nowPlayingArtworkSize, height: nowPlayingArtworkSize)
        ) { _ in image }
        #else
        let square = squareCroppedArtworkImage(image)
        let artwork = MPMediaItemArtwork(boundsSize: square.size) { _ in square }
        #endif
        nowPlayingArtworkCache.setObject(artwork, forKey: cacheKey as NSString)
        return artwork
    }

    private static func songArtworkSource(for artId: String) -> String {
        "song:\(artId)"
    }

    private static func songArtworkCacheKey(for imageCacheKey: String) -> String {
        "nowplaying:\(imageCacheKey)"
    }

    private static func baseSongInfo(for song: Song, currentTime: Double) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue as NSNumber
        if let d = song.duration { info[MPMediaItemPropertyPlaybackDuration] = Double(d) }
        return info
    }

    private static func debugArtwork(_ message: String) {
        #if DEBUG
        print("[ArtworkCache] \(message)")
        #endif
    }

    private static func uniqueArtworkIDs(from songs: [Song], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for song in songs {
            guard let artId = song.coverArt,
                  !artId.isEmpty,
                  seen.insert(artId).inserted
            else { continue }
            result.append(artId)
            if result.count == limit { break }
        }
        return result
    }
    #endif

    func updateRadio(station: RadioStationDisplayItem, metadata: RadioNowPlayingMetadata?, isPlaying: Bool) {
        prewarmArtworkTask?.cancel()
        prewarmArtworkTask = nil
        var info: [String: Any] = [:]
        let title = metadata?.displayTitle
        let artist = metadata?.displayArtist

        info[MPMediaItemPropertyTitle] = title ?? station.name
        info[MPMediaItemPropertyArtist] = artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = station.name
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue as NSNumber

        let remoteArtworkURL = station.usesDynamicSongCover ? metadata?.cacheBustedArtworkURL : nil
        let stationArtworkURL = station.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(for: $0, size: 600) }
        let artworkSources = radioArtworkSources(
            remoteArtworkURL: remoteArtworkURL,
            stationArtworkURL: stationArtworkURL,
            stationCoverArtID: station.coverArt
        )
        let cached = Self.cachedRadioArtwork(from: artworkSources)
        if let cached {
            currentArtwork = cached.artwork
            currentArtworkSource = cached.source
            currentArtworkIsFallback = cached.isFallback
        } else if currentArtworkSource == nil
            || !artworkSources.contains(where: { $0.identifier == currentArtworkSource }) {
            currentArtwork = nil
            currentArtworkSource = nil
            currentArtworkIsFallback = false
        }
        loadRadioArtworkIfNeeded(artworkSources)

        let attachesCurrentArtwork = currentArtwork != nil
            && currentArtworkSource != nil
            && artworkSources.contains(where: { $0.identifier == currentArtworkSource })

        if let currentArtwork,
           attachesCurrentArtwork {
            info[MPMediaItemPropertyArtwork] = currentArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadRadioArtworkIfNeeded(_ sources: [RadioArtworkSource]) {
        guard let primarySource = sources.first else {
            cancelArtwork()
            currentArtworkSource = nil
            currentArtwork = nil
            currentArtworkIsFallback = false
            return
        }
        let source = primarySource.identifier
        guard source != currentArtworkSource || currentArtwork == nil || currentArtworkIsFallback else {
            return
        }
        guard source != loadingArtworkSource else {
            return
        }
        cancelArtwork()
        loadingArtworkSource = source

        #if os(macOS)
        artworkTask = Task.detached(priority: .utility) { [weak self] in
            guard let loaded = await Self.loadRadioArtworkImage(from: sources),
                  !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishFailedRadioArtworkLoad(source: source)
                }
                return
            }
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { _ in loaded.image }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.loadingArtworkSource == source else { return }
                self.currentArtwork = artwork
                self.currentArtworkSource = loaded.source
                self.currentArtworkIsFallback = loaded.isFallback
                self.loadingArtworkSource = nil
                var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                updated[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
            }
        }
        #else
        artworkTask = Task.detached(priority: .utility) { [weak self] in
            guard let loaded = await Self.loadRadioArtworkImage(from: sources),
                  !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishFailedRadioArtworkLoad(source: source)
                }
                return
            }
            let square = Self.squareCroppedArtworkImage(loaded.image)
            let artwork = MPMediaItemArtwork(boundsSize: square.size) { _ in square }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.loadingArtworkSource == source else { return }
                self.currentArtwork = artwork
                self.currentArtworkSource = loaded.source
                self.currentArtworkIsFallback = loaded.isFallback
                self.loadingArtworkSource = nil
                var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                updated[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
            }
        }
        #endif
    }

    private func radioArtworkSources(
        remoteArtworkURL: URL?,
        stationArtworkURL: URL?,
        stationCoverArtID: String?
    ) -> [RadioArtworkSource] {
        var sources: [RadioArtworkSource] = []
        var seenURLs = Set<String>()

        func append(_ url: URL?, cacheKeys: [String], coverArtID: String? = nil) {
            guard let url,
                  seenURLs.insert(url.absoluteString).inserted
            else { return }
            sources.append(RadioArtworkSource(url: url, cacheKeys: cacheKeys, coverArtID: coverArtID))
        }

        append(remoteArtworkURL, cacheKeys: remoteArtworkURL.map { ["radio_remote_\($0.absoluteString)"] } ?? [])
        append(stationArtworkURL,
               cacheKeys: stationCoverArtID.map(Self.stationCoverCacheKeys) ?? [],
               coverArtID: stationCoverArtID)
        return sources
    }

    nonisolated private static func stationCoverCacheKeys(for coverArtID: String) -> [String] {
        [600, 300, 240, 200, 192, 180, 160, 156, 150, 120, 100, 80, 50].map { "\(coverArtID)_\($0)" }
    }

    @MainActor
    private func finishFailedRadioArtworkLoad(source: String) {
        guard loadingArtworkSource == source else { return }
        loadingArtworkSource = nil
        if currentArtwork == nil {
            currentArtworkSource = nil
            currentArtworkIsFallback = false
        }
    }

    #if os(macOS)
    private static func cachedRadioArtwork(from sources: [RadioArtworkSource]) -> (artwork: MPMediaItemArtwork, source: String, isFallback: Bool)? {
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: nowPlayingArtworkSize)
        for source in sources {
            guard let cached = ImageCacheService.shared.cachedImage(url: source.url, fallbackSizes: fallbackSizes) else { continue }
            let artworkKey = songArtworkCacheKey(for: cached.key)
            let artwork = nowPlayingArtwork(for: cached.image, cacheKey: artworkKey)
            let exactKey = ImageCacheService.stableCacheKey(for: source.url)
            return (artwork, source.identifier, cached.key != exactKey)
        }
        return nil
    }

    private static func loadRadioArtworkImage(from sources: [RadioArtworkSource]) async -> (image: NSImage, source: String, isFallback: Bool)? {
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: nowPlayingArtworkSize)
        for source in sources {
            if Task.isCancelled { return nil }
            let exactKey = ImageCacheService.stableCacheKey(for: source.url)
            if let coverArtID = source.coverArtID,
               let localPath = LocalArtworkIndex.shared.localPath(for: coverArtID),
               let localImage = NSImage(contentsOfFile: localPath) {
                ImageCacheService.shared.cache(localImage, url: source.url)
                return (localImage, source.identifier, false)
            }
            if let cached = await ImageCacheService.shared.diskOnlyImageResult(url: source.url, fallbackSizes: fallbackSizes) {
                return (cached.image, source.identifier, cached.key != exactKey)
            }
        }

        for source in sources {
            if Task.isCancelled { return nil }
            guard let image = await ImageCacheService.shared.image(url: source.url) else { continue }
            return (image, source.identifier, false)
        }
        return nil
    }
    #elseif os(iOS)
    private static func cachedRadioArtwork(from sources: [RadioArtworkSource]) -> (artwork: MPMediaItemArtwork, source: String, isFallback: Bool)? {
        for source in sources {
            let keys = source.cacheKeys.isEmpty ? ["radio_remote_\(source.url.absoluteString)"] : source.cacheKeys
            for (index, key) in keys.enumerated() {
                guard let image = ImageCacheService.shared.cachedImage(key: key) else { continue }
                let isFallback = index > 0
                let square = squareCroppedArtworkImage(image)
                let artwork = MPMediaItemArtwork(boundsSize: square.size) { _ in square }
                return (artwork, source.identifier, isFallback)
            }
        }
        return nil
    }

    private static func loadRadioArtworkImage(from sources: [RadioArtworkSource]) async -> (image: UIImage, source: String, isFallback: Bool)? {
        for source in sources {
            if Task.isCancelled { return nil }
            let cacheKeys = source.cacheKeys.isEmpty ? ["radio_remote_\(source.url.absoluteString)"] : source.cacheKeys
            let preferredKey = cacheKeys[0]

            if let image = ImageCacheService.shared.cachedImage(key: preferredKey) {
                return (image, source.identifier, false)
            }

            if let coverArtID = source.coverArtID,
               let localPath = LocalArtworkIndex.shared.localPath(for: coverArtID),
               let image = UIImage(contentsOfFile: localPath) {
                ImageCacheService.shared.cache(image, key: preferredKey)
                return (image, source.identifier, false)
            }

            if let image = await ImageCacheService.shared.diskOnlyImage(key: preferredKey, fallbackSizes: []) {
                return (image, source.identifier, false)
            }

            if source.coverArtID != nil, cacheKeys.count > 1 {
                for fallbackKey in cacheKeys.dropFirst() {
                    if let image = ImageCacheService.shared.cachedImage(key: fallbackKey) {
                        return (image, source.identifier, true)
                    }
                    if let image = await ImageCacheService.shared.diskOnlyImage(key: fallbackKey) {
                        return (image, source.identifier, true)
                    }
                }
            }
        }

        for source in sources {
            if Task.isCancelled { return nil }
            let cacheKeys = source.cacheKeys.isEmpty ? ["radio_remote_\(source.url.absoluteString)"] : source.cacheKeys
            let preferredKey = cacheKeys[0]

            if let image = await ImageCacheService.shared.image(url: source.url, key: preferredKey) {
                return (image, source.identifier, false)
            }
        }
        return nil
    }
    #else
    private static func cachedRadioArtwork(from sources: [RadioArtworkSource]) -> (artwork: MPMediaItemArtwork, source: String, isFallback: Bool)? {
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: nowPlayingArtworkSize)
        for source in sources {
            guard let cached = ImageCacheService.shared.cachedImage(url: source.url, fallbackSizes: fallbackSizes) else { continue }
            let artworkKey = songArtworkCacheKey(for: cached.key)
            let artwork = nowPlayingArtwork(for: cached.image, cacheKey: artworkKey)
            let exactKey = ImageCacheService.stableCacheKey(for: source.url)
            return (artwork, source.identifier, cached.key != exactKey)
        }
        return nil
    }

    private static func loadRadioArtworkImage(from sources: [RadioArtworkSource]) async -> (image: UIImage, source: String, isFallback: Bool)? {
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: nowPlayingArtworkSize)
        for source in sources {
            if Task.isCancelled { return nil }
            let exactKey = ImageCacheService.stableCacheKey(for: source.url)
            if let coverArtID = source.coverArtID,
               let localPath = LocalArtworkIndex.shared.localPath(for: coverArtID),
               let localImage = UIImage(contentsOfFile: localPath) {
                ImageCacheService.shared.cache(localImage, url: source.url)
                return (localImage, source.identifier, false)
            }
            if let cached = await ImageCacheService.shared.diskOnlyImageResult(url: source.url, fallbackSizes: fallbackSizes) {
                return (cached.image, source.identifier, cached.key != exactKey)
            }
        }

        for source in sources {
            if Task.isCancelled { return nil }
            guard let image = await ImageCacheService.shared.image(url: source.url) else { continue }
            return (image, source.identifier, false)
        }
        return nil
    }
    #endif

    #if !os(macOS)
    nonisolated private static func squareCroppedArtworkImage(_ image: UIImage) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        guard width != height else { return image }
        let side = min(width, height)
        let scale = image.scale
        let cropRect = CGRect(
            x: ((width - side) / 2) * scale,
            y: ((height - side) / 2) * scale,
            width: side * scale,
            height: side * scale
        )
        guard let croppedImage = image.cgImage?.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: croppedImage, scale: scale, orientation: image.imageOrientation)
    }
    #endif

    func cancelArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        loadingArtworkSource = nil
    }

    @discardableResult
    func reapplyCurrentArtwork() -> Bool {
        guard let currentArtwork else { return false }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = currentArtwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        return true
    }

    func clear() {
        cancelArtwork()
        prewarmArtworkTask?.cancel()
        prewarmArtworkTask = nil
        currentArtwork = nil
        currentArtworkSource = nil
        currentArtworkIsFallback = false
        lastReportedTime = -1
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func applyPlaybackMode(isShuffled: Bool, repeatMode: RepeatMode) {
        let cc = MPRemoteCommandCenter.shared()
        cc.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
        switch repeatMode {
        case .off: cc.changeRepeatModeCommand.currentRepeatType = .off
        case .one: cc.changeRepeatModeCommand.currentRepeatType = .one
        case .all: cc.changeRepeatModeCommand.currentRepeatType = .all
        }
    }

    func updatePlaybackRate(_ rate: Double, currentTime: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateTime(_ time: Double, force: Bool = false) {
        guard force || abs(time - lastReportedTime) >= 0.5 else { return }
        lastReportedTime = time
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
