import AVFoundation
import Combine
import Foundation

final class CrossfadeEngine: ObservableObject {

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isCrossfading: Bool = false

    var crossfadeDuration: TimeInterval = 5
    var trustedDuration: TimeInterval = 0
    var onTrackFinished: ((Bool) -> Void)?

    private let playerA: AVQueuePlayer
    private let playerB: AVQueuePlayer
    private var activePlayer: AVQueuePlayer
    private var inactivePlayer: AVQueuePlayer

    private var timeObserverToken: Any?
    private var timeObserverPlayer: AVPlayer?
    private var fadeCancellable: AnyCancellable?
    private var fadeStartDate: Date?
    private var itemFinishedObserver: NSObjectProtocol?
    private var itemFailureObserver: NSObjectProtocol?
    private var itemStallObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var currentURL: URL?
    private var retryCount: Int = 0
    private let maxRetries: Int = 3
    private var isTranscoded: Bool = false
    private var gaplessPreloaded = false
    private var gaplessPreloadIsTranscoded: Bool = false
    private var gaplessNextItem: AVPlayerItem?
    private var isSeeking = false

    init() {
        let a = AVQueuePlayer()
        let b = AVQueuePlayer()
        a.allowsExternalPlayback = false
        b.allowsExternalPlayback = false
        a.automaticallyWaitsToMinimizeStalling = false
        b.automaticallyWaitsToMinimizeStalling = false
        playerA = a
        playerB = b
        activePlayer = a
        inactivePlayer = b
    }

    deinit {
        cancelFade()
        removeTimeObserver()
        removeItemFinishedObserver()
        itemStatusObservation?.invalidate()
        if let obs = itemFailureObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = itemStallObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Public API

    func play(url: URL, isTranscoded: Bool = false) {
        currentURL = url
        retryCount = 0
        trustedDuration = 0
        gaplessPreloaded = false
        gaplessPreloadIsTranscoded = false
        gaplessNextItem = nil
        self.isTranscoded = isTranscoded
        loadAndPlay(url: url)
    }

    private func loadAndPlay(url: URL) {
        cancelFade()
        isCrossfading = false
        gaplessPreloaded = false
        gaplessNextItem = nil

        inactivePlayer.pause()
        inactivePlayer.removeAllItems()
        inactivePlayer.volume = 1.0

        let item = makePlayerItem(url: url)
        activePlayer.pause()
        activePlayer.removeAllItems()
        activePlayer.automaticallyWaitsToMinimizeStalling = isTranscoded
        activePlayer.insert(item, after: nil)
        activePlayer.volume = 1.0
        activePlayer.play()

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
                Task { @MainActor in self.scheduleRetry(for: url) }
            }
        }

        if let obs = itemFailureObserver { NotificationCenter.default.removeObserver(obs) }
        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scheduleRetry(for: url) }
        }

        if let obs = itemStallObserver { NotificationCenter.default.removeObserver(obs) }
        itemStallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, let currentItem = self.activePlayer.currentItem else { return }
            if currentItem.status == .failed {
                Task { @MainActor in self.scheduleRetry(for: url) }
            }
        }
    }

    @MainActor
    private func scheduleRetry(for url: URL) {
        guard currentURL == url else { return }
        guard retryCount < maxRetries else { return }
        retryCount += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard self.currentURL == url else { return }
            self.loadAndPlay(url: url)
        }
    }

    func triggerCrossfade(nextURL: URL, isTranscoded: Bool = false) {
        inactivePlayer.pause()
        inactivePlayer.removeAllItems()
        inactivePlayer.automaticallyWaitsToMinimizeStalling = isTranscoded
        let item = makePlayerItem(url: nextURL)
        inactivePlayer.insert(item, after: nil)
        inactivePlayer.volume = 0
        beginFade()
    }

    // Gapless: inserts next item directly into the active player's queue.
    // AVQueuePlayer transitions between items with no audio pipeline interruption.
    func preloadForGapless(url: URL, isTranscoded: Bool = false) {
        gaplessPreloadIsTranscoded = isTranscoded
        guard let currentItem = activePlayer.currentItem else { return }
        let nextItem = makePlayerItem(url: url)
        gaplessNextItem = nextItem
        activePlayer.insert(nextItem, after: currentItem)
        gaplessPreloaded = true
    }

    private func performGaplessSwap() {
        // AVQueuePlayer already advanced to the next item seamlessly — no swap, no seek needed.
        removeItemFinishedObserver()
        trustedDuration = 0
        gaplessPreloaded = false
        gaplessPreloadIsTranscoded = false
        currentTime = 0
        isPlaying = true

        if let nextItem = gaplessNextItem {
            gaplessNextItem = nil
            setupItemFinishedObserverForItem(nextItem)
        } else {
            setupItemFinishedObserver()
        }
    }

    func pause() {
        activePlayer.pause()
        if isCrossfading { inactivePlayer.pause() }
        isPlaying = false
    }

    func resume() {
        activePlayer.play()
        if isCrossfading { inactivePlayer.play() }
        isPlaying = true
    }

    func seek(to seconds: TimeInterval, completion: ((Bool) -> Void)? = nil) {
        if isCrossfading {
            cancelFade()
            inactivePlayer.pause()
            inactivePlayer.removeAllItems()
            inactivePlayer.volume = 1.0
            isCrossfading = false
        }
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        isSeeking = true
        currentTime = seconds
        activePlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            self?.isSeeking = false
            completion?(finished)
        }
    }

    func stop() {
        cancelFade()
        removeTimeObserver()
        removeItemFinishedObserver()
        removeFailureObservation()
        currentURL = nil
        retryCount = 0
        gaplessNextItem = nil
        activePlayer.pause()
        activePlayer.removeAllItems()
        inactivePlayer.pause()
        inactivePlayer.removeAllItems()
        inactivePlayer.volume = 1.0
        isPlaying = false
        isCrossfading = false
        gaplessPreloaded = false
        currentTime = 0
        duration = 0
    }

    private func makePlayerItem(url: URL) -> AVPlayerItem {
        let asset: AVURLAsset
        if url.isFileURL {
            asset = AVURLAsset(url: url)
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
        if let obs = itemFailureObserver {
            NotificationCenter.default.removeObserver(obs)
            itemFailureObserver = nil
        }
        if let obs = itemStallObserver {
            NotificationCenter.default.removeObserver(obs)
            itemStallObserver = nil
        }
    }

    // MARK: - Crossfade

    private func beginFade() {
        isCrossfading = true
        fadeStartDate = Date()
        inactivePlayer.seek(to: .zero)
        inactivePlayer.play()

        fadeCancellable = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.fadeStep() }
    }

    private func fadeStep() {
        guard let start = fadeStartDate else { return }
        let progress = min(Date().timeIntervalSince(start) / crossfadeDuration, 1.0)
        activePlayer.volume = Float(1.0 - progress)
        inactivePlayer.volume = Float(progress)
        let t = inactivePlayer.currentTime().seconds
        if t.isFinite { currentTime = t }
        if progress >= 1.0 { completeFade() }
    }

    private func completeFade() {
        cancelFade()
        removeTimeObserver()
        removeItemFinishedObserver()

        let outgoing = activePlayer
        outgoing.pause()
        outgoing.removeAllItems()
        outgoing.volume = 1.0

        swap(&activePlayer, &inactivePlayer)
        activePlayer.volume = 1.0
        isCrossfading = false
        isPlaying = true

        setupTimeObserver()
        setupItemFinishedObserver()
        onTrackFinished?(false)
    }

    private func cancelFade() {
        fadeCancellable?.cancel()
        fadeCancellable = nil
        fadeStartDate = nil
    }

    // MARK: - Observers

    private func setupTimeObserver() {
        removeTimeObserver()
        let player = activePlayer
        let interval = CMTime(seconds: 0.5, preferredTimescale: 1000)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.refreshDuration()
            guard !self.isCrossfading, !self.isSeeking else { return }
            self.currentTime = time.seconds
        }
        timeObserverPlayer = player
    }

    private func removeTimeObserver() {
        guard let token = timeObserverToken, let player = timeObserverPlayer else { return }
        player.removeTimeObserver(token)
        timeObserverToken = nil
        timeObserverPlayer = nil
    }

    private func setupItemFinishedObserver() {
        guard let item = activePlayer.currentItem else { return }
        setupItemFinishedObserverForItem(item)
    }

    private func setupItemFinishedObserverForItem(_ item: AVPlayerItem) {
        removeItemFinishedObserver()
        itemFinishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isCrossfading else { return }
            if self.gaplessPreloaded {
                self.performGaplessSwap()
                self.onTrackFinished?(true)
            } else {
                self.isPlaying = false
                self.onTrackFinished?(false)
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
        guard let item = activePlayer.currentItem else { return }
        let d = item.duration.seconds
        if d.isFinite && d > 0 { duration = d }
    }
}
