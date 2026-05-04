import AVFoundation
import Combine
import Foundation

final class PlayerEngine: ObservableObject {

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isWaiting: Bool = false
    @Published private(set) var isLikelyToKeepUp: Bool = true

    var trustedDuration: TimeInterval = 0
    var onTrackFinished: (() -> Void)?
    var onPlaybackFailed: (() -> Void)?

    private let player: AVQueuePlayer
    private var timeObserverToken: Any?
    private var itemFinishedObserver: NSObjectProtocol?
    private var itemFailureObserver: NSObjectProtocol?
    private var itemStallObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var likelyKeepUpObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var currentURL: URL?
    private var hasFailed = false
    private var isSeeking = false
    private var gaplessNextItem: AVPlayerItem?
    private var gaplessNextURL: URL?
    private var gaplessPreloaded = false
    private var pendingResumeAfterBuffer = false

    init() {
        let p = AVQueuePlayer()
        p.allowsExternalPlayback = false
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        timeControlObservation = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor [weak self] in self?.isWaiting = waiting }
        }
    }

    deinit {
        removeTimeObserver()
        removeItemFinishedObserver()
        itemStatusObservation?.invalidate()
        likelyKeepUpObservation?.invalidate()
        timeControlObservation?.invalidate()
        if let obs = itemFailureObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = itemStallObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func play(url: URL) {
        currentURL = url
        trustedDuration = 0
        gaplessPreloaded = false
        gaplessNextItem = nil
        gaplessNextURL = nil
        loadAndPlay(url: url)
    }

    private func loadAndPlay(url: URL) {
        hasFailed = false
        gaplessPreloaded = false
        gaplessNextItem = nil
        gaplessNextURL = nil
        pendingResumeAfterBuffer = false
        isSeeking = false

        let item = makePlayerItem(url: url)
        player.pause()
        player.removeAllItems()
        player.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        player.insert(item, after: nil)
        player.play()

        isPlaying = true
        setupTimeObserver()
        setupItemFinishedObserverForItem(item)
        setupFailureObservation(item: item, url: url)
    }

    private func setupFailureObservation(item: AVPlayerItem, url: URL) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard let self else { return }
            if observedItem.status == .failed {
                Task { @MainActor in self.notifyFailure(for: url) }
            }
        }

        likelyKeepUpObservation?.invalidate()
        likelyKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] observedItem, _ in
            let likely = observedItem.isPlaybackLikelyToKeepUp
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLikelyToKeepUp = likely
                if likely && self.pendingResumeAfterBuffer {
                    self.pendingResumeAfterBuffer = false
                    self.player.play()
                    self.isPlaying = true
                }
            }
        }

        if let obs = itemFailureObserver { NotificationCenter.default.removeObserver(obs) }
        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.notifyFailure(for: url) }
        }

        if let obs = itemStallObserver { NotificationCenter.default.removeObserver(obs) }
        itemStallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, let currentItem = self.player.currentItem else { return }
            if currentItem.status == .failed {
                Task { @MainActor in self.notifyFailure(for: url) }
            }
        }
    }

    @MainActor
    private func notifyFailure(for url: URL) {
        guard currentURL == url, !hasFailed else { return }
        hasFailed = true
        isPlaying = false
        onPlaybackFailed?()
    }

    func preloadForGapless(url: URL) {
        guard let currentItem = player.currentItem else { return }
        let nextItem = makePlayerItem(url: url)
        gaplessNextItem = nextItem
        gaplessNextURL = url
        player.insert(nextItem, after: currentItem)
        gaplessPreloaded = true
    }

    private func performGaplessSwap() {
        removeItemFinishedObserver()
        trustedDuration = 0
        hasFailed = false
        gaplessPreloaded = false
        pendingResumeAfterBuffer = false
        currentTime = 0
        isPlaying = true
        isSeeking = false

        let swappedURL = gaplessNextURL
        let swappedItem = gaplessNextItem
        gaplessNextURL = nil
        gaplessNextItem = nil

        if let url = swappedURL {
            currentURL = url
            player.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        }

        if let item = swappedItem {
            setupItemFinishedObserverForItem(item)
            if let url = swappedURL {
                setupFailureObservation(item: item, url: url)
                if item.status == .failed {
                    Task { @MainActor [weak self] in self?.notifyFailure(for: url) }
                }
            }
        } else {
            setupItemFinishedObserver()
        }
    }

    func pause() {
        // User-Pause: pendingResumeAfterBuffer löschen, sonst würde der Player nach Buffer-Ready
        // gegen den User-Wunsch wieder anspringen.
        pendingResumeAfterBuffer = false
        player.pause()
        isPlaying = false
    }

    func resume() {
        // User-Resume: pendingResumeAfterBuffer löschen — User hat aktiv Play gedrückt,
        // also liegt die Kontrolle nicht mehr beim Buffer-Watcher.
        pendingResumeAfterBuffer = false
        player.play()
        isPlaying = true
    }

    func seek(to seconds: TimeInterval, pauseUntilBuffered: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        isSeeking = true
        currentTime = seconds
        if pauseUntilBuffered {
            // Player aktiv pausieren während AVPlayer auf Buffer wartet — verhindert dass
            // der Player im Hintergrund weiterläuft (interne Zeit advanciert) ohne Audio.
            // KVO auf isPlaybackLikelyToKeepUp resumed automatisch sobald genug Buffer da ist.
            player.pause()
            isPlaying = false
            pendingResumeAfterBuffer = true
        }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            self?.isSeeking = false
            completion?(finished)
        }
    }

    func isPositionBuffered(_ seconds: TimeInterval) -> Bool {
        guard let item = player.currentItem else { return false }
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = start + range.duration.seconds
            if seconds >= start && seconds <= end { return true }
        }
        return false
    }

    func stop() {
        removeTimeObserver()
        removeItemFinishedObserver()
        removeFailureObservation()
        currentURL = nil
        hasFailed = false
        gaplessNextItem = nil
        gaplessNextURL = nil
        pendingResumeAfterBuffer = false
        player.pause()
        player.removeAllItems()
        isPlaying = false
        isWaiting = false
        isLikelyToKeepUp = true
        gaplessPreloaded = false
        currentTime = 0
        duration = 0
    }

    private func makePlayerItem(url: URL) -> AVPlayerItem {
        let asset: AVURLAsset
        if url.isFileURL {
            asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        } else {
            let headers: [String: String] = ["Range": "bytes=0-"]
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        return item
    }

    private func removeFailureObservation() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        likelyKeepUpObservation?.invalidate()
        likelyKeepUpObservation = nil
        if let obs = itemFailureObserver {
            NotificationCenter.default.removeObserver(obs)
            itemFailureObserver = nil
        }
        if let obs = itemStallObserver {
            NotificationCenter.default.removeObserver(obs)
            itemStallObserver = nil
        }
    }

    private func setupTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 1000)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.refreshDuration()
            guard !self.isSeeking else { return }
            self.currentTime = time.seconds
        }
    }

    private func removeTimeObserver() {
        guard let token = timeObserverToken else { return }
        player.removeTimeObserver(token)
        timeObserverToken = nil
    }

    private func setupItemFinishedObserver() {
        guard let item = player.currentItem else { return }
        setupItemFinishedObserverForItem(item)
    }

    private func setupItemFinishedObserverForItem(_ item: AVPlayerItem) {
        removeItemFinishedObserver()
        itemFinishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.gaplessPreloaded {
                self.performGaplessSwap()
                self.onTrackFinished?()
            } else {
                self.isPlaying = false
                self.onTrackFinished?()
            }
        }
    }

    private func removeItemFinishedObserver() {
        guard let obs = itemFinishedObserver else { return }
        NotificationCenter.default.removeObserver(obs)
        itemFinishedObserver = nil
    }

    private func refreshDuration() {
        if trustedDuration > 0 {
            duration = trustedDuration
            return
        }
        guard let item = player.currentItem else { return }
        let d = item.duration.seconds
        if d.isFinite && d > 0 { duration = d }
    }
}
