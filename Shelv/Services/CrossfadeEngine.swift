import AVFoundation
import Combine
import Foundation

final class CrossfadeEngine: ObservableObject {

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false
    private(set) var isCrossfading: Bool = false

    var crossfadeDuration: TimeInterval = 5
    var onTrackFinished: (() -> Void)?

    private let playerA: AVPlayer
    private let playerB: AVPlayer
    private var activePlayer: AVPlayer
    private var inactivePlayer: AVPlayer

    private var timeObserverToken: Any?
    private var timeObserverPlayer: AVPlayer?
    private var fadeCancellable: AnyCancellable?
    private var fadeStartDate: Date?
    private var itemFinishedObserver: NSObjectProtocol?

    init() {
        let a = AVPlayer()
        let b = AVPlayer()
        a.allowsExternalPlayback = false
        b.allowsExternalPlayback = false
        playerA = a
        playerB = b
        activePlayer = a
        inactivePlayer = b
    }

    deinit {
        cancelFade()
        removeTimeObserver()
        removeItemFinishedObserver()
    }

    // MARK: - Public API

    func play(url: URL) {
        cancelFade()
        isCrossfading = false

        inactivePlayer.pause()
        inactivePlayer.replaceCurrentItem(with: nil)
        inactivePlayer.volume = 1.0

        let item = AVPlayerItem(url: url)
        activePlayer.replaceCurrentItem(with: item)
        activePlayer.volume = 1.0
        activePlayer.play()

        isPlaying = true
        setupTimeObserver()
        setupItemFinishedObserver()
    }

    func triggerCrossfade(nextURL: URL) {
        inactivePlayer.replaceCurrentItem(with: AVPlayerItem(url: nextURL))
        inactivePlayer.volume = 0
        beginFade()
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

    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        activePlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func stop() {
        cancelFade()
        removeTimeObserver()
        removeItemFinishedObserver()
        activePlayer.pause()
        activePlayer.replaceCurrentItem(with: nil)
        inactivePlayer.pause()
        inactivePlayer.replaceCurrentItem(with: nil)
        inactivePlayer.volume = 1.0
        isPlaying = false
        isCrossfading = false
        currentTime = 0
        duration = 0
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
        currentTime = inactivePlayer.currentTime().seconds
        if progress >= 1.0 { completeFade() }
    }

    private func completeFade() {
        cancelFade()
        removeTimeObserver()
        removeItemFinishedObserver()

        let outgoing = activePlayer
        outgoing.pause()
        outgoing.replaceCurrentItem(with: nil)
        outgoing.volume = 1.0

        swap(&activePlayer, &inactivePlayer)
        activePlayer.volume = 1.0
        isCrossfading = false
        isPlaying = true

        setupTimeObserver()
        setupItemFinishedObserver()
        onTrackFinished?()
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
            self.currentTime = time.seconds
            self.refreshDuration()
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
        removeItemFinishedObserver()
        guard let item = activePlayer.currentItem else { return }
        itemFinishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isCrossfading else { return }
            self.isPlaying = false
            self.onTrackFinished?()
        }
    }

    private func removeItemFinishedObserver() {
        guard let obs = itemFinishedObserver else { return }
        NotificationCenter.default.removeObserver(obs)
        itemFinishedObserver = nil
    }

    private func refreshDuration() {
        guard let item = activePlayer.currentItem else { return }
        let d = item.duration.seconds
        if d.isFinite && d > 0 { duration = d }
    }
}
