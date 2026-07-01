import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

private struct RadioArtworkSource: Sendable {
    let url: URL
    let cacheKey: String?

    var identifier: String { url.absoluteString }
}

final class AudioPlayerNowPlayingController {
    private var currentArtwork: MPMediaItemArtwork?
    private var currentArtworkSource: String?
    private var loadingArtworkSource: String?
    private var artworkTask: Task<Void, Never>?
    private var lastReportedTime: Double = -1

    func update(song: Song, currentTime: Double) {
        cancelArtwork()
        currentArtworkSource = nil
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
            let key = "\(artId)_600"
            let isOffline = OfflineModeService.shared.isOffline
            artworkTask = Task { [weak self] in
                var img: UIImage?
                if Task.isCancelled { return }
                if let localPath = LocalArtworkIndex.shared.localPath(for: artId) {
                    img = await Task.detached(priority: .medium) { UIImage(contentsOfFile: localPath) }.value
                }
                if img == nil {
                    if isOffline {
                        img = await ImageCacheService.shared.diskOnlyImage(key: key)
                    } else {
                        for attempt in 1...3 {
                            if Task.isCancelled { return }
                            img = await ImageCacheService.shared.image(url: artURL, key: key)
                            if img != nil { break }
                            if attempt < 3 { try? await Task.sleep(for: .milliseconds(500)) }
                        }
                    }
                }
                guard let img, !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let square = Self.squareCroppedArtworkImage(img)
                    let artwork = MPMediaItemArtwork(boundsSize: square.size) { _ in square }
                    self.currentArtwork = artwork
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updated[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
            #elseif os(macOS)
            artworkTask = Task.detached(priority: .utility) { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: artURL),
                      !Task.isCancelled,
                      let nsImage = NSImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { _ in nsImage }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.currentArtwork = artwork
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updated[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
            #else
            artworkTask = Task.detached(priority: .utility) { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: artURL),
                      !Task.isCancelled,
                      let uiImage = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { _ in uiImage }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.currentArtwork = artwork
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updated[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
            #endif
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateRadio(station: RadioStationDisplayItem, metadata: RadioNowPlayingMetadata?, isPlaying: Bool) {
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
        loadRadioArtworkIfNeeded(artworkSources)

        if let currentArtwork,
           let currentArtworkSource,
           artworkSources.contains(where: { $0.identifier == currentArtworkSource }) {
            info[MPMediaItemPropertyArtwork] = currentArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadRadioArtworkIfNeeded(_ sources: [RadioArtworkSource]) {
        guard let primarySource = sources.first else {
            cancelArtwork()
            currentArtworkSource = nil
            currentArtwork = nil
            return
        }
        let source = primarySource.identifier
        guard source != currentArtworkSource || currentArtwork == nil else { return }
        guard source != loadingArtworkSource else { return }
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

        func append(_ url: URL?, cacheKey: String?) {
            guard let url,
                  seenURLs.insert(url.absoluteString).inserted
            else { return }
            sources.append(RadioArtworkSource(url: url, cacheKey: cacheKey))
        }

        append(remoteArtworkURL, cacheKey: remoteArtworkURL.map { "radio_remote_\($0.absoluteString)" })
        append(stationArtworkURL, cacheKey: stationCoverArtID.map { "\($0)_600" })
        return sources
    }

    @MainActor
    private func finishFailedRadioArtworkLoad(source: String) {
        guard loadingArtworkSource == source else { return }
        loadingArtworkSource = nil
        if currentArtwork == nil {
            currentArtworkSource = nil
        }
    }

    #if os(macOS)
    private static func loadRadioArtworkImage(from sources: [RadioArtworkSource]) async -> (image: NSImage, source: String)? {
        for source in sources {
            if Task.isCancelled { return nil }
            guard let image = await ImageCacheService.shared.image(url: source.url) else { continue }
            return (image, source.identifier)
        }
        return nil
    }
    #elseif os(iOS)
    private static func loadRadioArtworkImage(from sources: [RadioArtworkSource]) async -> (image: UIImage, source: String)? {
        for source in sources {
            if Task.isCancelled { return nil }
            let cacheKey = source.cacheKey ?? "radio_remote_\(source.url.absoluteString)"
            guard let image = await ImageCacheService.shared.image(url: source.url, key: cacheKey) else { continue }
            return (image, source.identifier)
        }
        return nil
    }
    #else
    private static func loadRadioArtworkImage(from sources: [RadioArtworkSource]) async -> (image: UIImage, source: String)? {
        for source in sources {
            if Task.isCancelled { return nil }
            guard let image = await ImageCacheService.shared.image(url: source.url) else { continue }
            return (image, source.identifier)
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

    func clear() {
        cancelArtwork()
        currentArtwork = nil
        currentArtworkSource = nil
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
