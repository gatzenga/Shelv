import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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

        let remoteArtworkURL = station.metadata.showSongCover ? metadata?.cacheBustedArtworkURL : nil
        let stationArtworkURL = station.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(for: $0, size: 600) }
        loadRadioArtworkIfNeeded(remoteArtworkURL ?? stationArtworkURL, fallbackURL: remoteArtworkURL == nil ? nil : stationArtworkURL)

        if let currentArtwork {
            info[MPMediaItemPropertyArtwork] = currentArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadRadioArtworkIfNeeded(_ url: URL?, fallbackURL: URL? = nil) {
        let source = url?.absoluteString
        guard source != nil else {
            cancelArtwork()
            currentArtworkSource = nil
            currentArtwork = nil
            return
        }
        guard source != currentArtworkSource || currentArtwork == nil else { return }
        guard source != loadingArtworkSource else { return }
        cancelArtwork()
        loadingArtworkSource = source
        guard let source else { return }
        var seenURLs = Set<String>()
        let urls = [url, fallbackURL]
            .compactMap { $0 }
            .filter { seenURLs.insert($0.absoluteString).inserted }
        guard !urls.isEmpty else {
            loadingArtworkSource = nil
            return
        }

        #if os(macOS)
        artworkTask = Task.detached(priority: .utility) { [weak self] in
            guard let loaded = await Self.loadRadioArtworkImage(from: urls),
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
            guard let loaded = await Self.loadRadioArtworkImage(from: urls),
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

    @MainActor
    private func finishFailedRadioArtworkLoad(source: String) {
        guard loadingArtworkSource == source else { return }
        loadingArtworkSource = nil
        if currentArtwork == nil {
            currentArtworkSource = nil
        }
    }

    #if os(macOS)
    private static func loadRadioArtworkImage(from urls: [URL]) async -> (image: NSImage, source: String)? {
        for url in urls {
            if Task.isCancelled { return nil }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 12
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  isSuccessfulImageResponse(response),
                  let image = NSImage(data: data)
            else { continue }
            return (image, url.absoluteString)
        }
        return nil
    }
    #else
    private static func loadRadioArtworkImage(from urls: [URL]) async -> (image: UIImage, source: String)? {
        for url in urls {
            if Task.isCancelled { return nil }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 12
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  isSuccessfulImageResponse(response),
                  let image = UIImage(data: data)
            else { continue }
            return (image, url.absoluteString)
        }
        return nil
    }

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

    private static func isSuccessfulImageResponse(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }

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
