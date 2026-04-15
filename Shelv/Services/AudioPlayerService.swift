import AVFoundation
import MediaPlayer
import Combine
import UIKit
import SwiftUI

enum RepeatMode: String {
    case off, all, one

    var toggled: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var systemImage: String {
        self == .one ? "repeat.1" : "repeat"
    }
}

class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published var isPlaying: Bool = false
    @Published var isBuffering: Bool = false
    @Published var currentSong: Song?
    @Published var queue: [Song] = []
    @Published var currentIndex: Int = 0
    @Published var playNextQueue: [Song] = []
    @Published var userQueue: [Song] = []
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isAirPlayActive: Bool = false
    @Published var isSeeking: Bool = false
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off

    var hasNextTrack: Bool {
        !playNextQueue.isEmpty ||
        currentIndex + 1 < queue.count ||
        !userQueue.isEmpty ||
        repeatMode == .all
    }

    var displayTitle: String {
        currentSong?.title ?? tr("No Track", "Kein Titel")
    }

    private var shuffleSnapshot: ShuffleSnapshot?

    private struct ShuffleSnapshot {
        var playNextQueue: [Song]
        var queue: [Song]
        var currentIndex: Int
        var userQueue: [Song]
    }

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var currentArtwork: MPMediaItemArtwork?
    private var artworkTask: URLSessionDataTask?

    private var pendingSeekTime: Double = 0
    private var resumeTime: Double = 0

    private enum StateKey {
        static let queue          = "shelv_player_queue"
        static let index          = "shelv_player_currentIndex"
        static let playNextQueue  = "shelv_player_playNextQueue"
        static let userQueue      = "shelv_player_userQueue"
        static let resumeTime     = "shelv_player_resumeTime"
        static let isShuffled     = "shelv_player_isShuffled"
        static let repeatMode     = "shelv_player_repeatMode"
    }

    private init() {
        setupAudioSession()
        setupRemoteControls()
        setupRouteObserver()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        restoreState()
    }

    @objc private func appDidEnterBackground() {
        saveState()
    }

    private func saveState() {
        let encoder = JSONEncoder()
        let defaults = UserDefaults.standard
        if let data = try? encoder.encode(queue) { defaults.set(data, forKey: StateKey.queue) }
        defaults.set(currentIndex, forKey: StateKey.index)
        if let data = try? encoder.encode(playNextQueue) { defaults.set(data, forKey: StateKey.playNextQueue) }
        if let data = try? encoder.encode(userQueue) { defaults.set(data, forKey: StateKey.userQueue) }
        defaults.set(currentTime, forKey: StateKey.resumeTime)
        defaults.set(isShuffled, forKey: StateKey.isShuffled)
        defaults.set(repeatMode.rawValue, forKey: StateKey.repeatMode)
    }

    private func clearSavedState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: StateKey.queue)
        defaults.removeObject(forKey: StateKey.index)
        defaults.removeObject(forKey: StateKey.playNextQueue)
        defaults.removeObject(forKey: StateKey.userQueue)
        defaults.removeObject(forKey: StateKey.resumeTime)
        defaults.removeObject(forKey: StateKey.isShuffled)
        defaults.removeObject(forKey: StateKey.repeatMode)
    }

    private func restoreState() {
        let decoder = JSONDecoder()
        let defaults = UserDefaults.standard

        guard let queueData = defaults.data(forKey: StateKey.queue),
              let restoredQueue = try? decoder.decode([Song].self, from: queueData),
              !restoredQueue.isEmpty
        else { return }

        queue = restoredQueue
        let idx = defaults.integer(forKey: StateKey.index)
        currentIndex = min(max(idx, 0), restoredQueue.count - 1)
        currentSong = restoredQueue[currentIndex]
        resumeTime = defaults.double(forKey: StateKey.resumeTime)
        currentTime = resumeTime
        if let d = currentSong?.duration { duration = Double(d) }

        if let pnData = defaults.data(forKey: StateKey.playNextQueue),
           let pn = try? decoder.decode([Song].self, from: pnData) {
            playNextQueue = pn
        }
        if let uqData = defaults.data(forKey: StateKey.userQueue),
           let uq = try? decoder.decode([Song].self, from: uqData) {
            userQueue = uq
        }

        isShuffled = defaults.bool(forKey: StateKey.isShuffled)
        if let raw = defaults.string(forKey: StateKey.repeatMode) {
            repeatMode = RepeatMode(rawValue: raw) ?? .off
        }

        updateNowPlayingInfo(song: currentSong!)
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetoothHFP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
    }

    private func setupRouteObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        updateAirPlayState()
    }

    @objc private func audioRouteChanged() {
        updateAirPlayState()
    }

    func updateAirPlayState() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let active = outputs.contains {
            $0.portType == .airPlay ||
            $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothLE ||
            $0.portType == .bluetoothHFP
        }
        DispatchQueue.main.async { self.isAirPlayActive = active }
    }

    private func setupRemoteControls() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }

        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.next(triggeredByUser: true); return .success
        }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous(); return .success
        }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    func play(songs: [Song], startIndex: Int = 0) {
        shuffleSnapshot = nil
        isShuffled = false
        queue = songs
        currentIndex = startIndex
        playNextQueue = []
        userQueue = []
        guard songs.indices.contains(startIndex) else { return }
        resumeTime = 0
        startPlayback(song: songs[startIndex])
        saveState()
    }

    func playSong(_ song: Song) {
        shuffleSnapshot = nil
        isShuffled = false
        queue = [song]
        currentIndex = 0
        playNextQueue = []
        userQueue = []
        resumeTime = 0
        startPlayback(song: song)
        saveState()
    }

    private func startPlayback(song: Song) {
        guard let url = SubsonicAPIService.shared.streamURL(for: song.id) else { return }

        teardownPlayer()
        currentSong = song
        isBuffering = true
        currentTime = 0
        duration = 0

        let seekTo = pendingSeekTime
        pendingSeekTime = 0

        let headers: [String: String] = ["Range": "bytes=0-"]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        playerItem = AVPlayerItem(asset: asset)
        playerItem?.preferredForwardBufferDuration = 10

        player = AVPlayer(playerItem: playerItem)
        player?.allowsExternalPlayback = true
        player?.automaticallyWaitsToMinimizeStalling = true

        statusObserver = playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .readyToPlay {
                    if let d = self.playerItem?.duration, d.isNumeric {
                        self.duration = d.seconds
                    }
                    if seekTo > 0 {
                        let seekTime = CMTime(seconds: seekTo, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                        self.player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                            DispatchQueue.main.async { self?.player?.play() }
                        }
                    } else {
                        self.player?.play()
                    }
                } else if item.status == .failed {
                    self.isBuffering = false
                }
            }
        }

        timeControlObserver = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            DispatchQueue.main.async {
                switch avPlayer.timeControlStatus {
                case .playing:
                    self?.isBuffering = false
                    self?.isPlaying = true
                case .waitingToPlayAtSpecifiedRate:
                    self?.isBuffering = true
                case .paused:
                    break
                @unknown default:
                    break
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isSeeking else { return }
            self.currentTime = time.seconds
            if let d = self.playerItem?.duration, d.isNumeric, d.seconds > 0 {
                self.duration = d.seconds
            }
        }

        isPlaying = true
        updateNowPlayingInfo(song: song)
        Task { await SubsonicAPIService.shared.scrobble(songId: song.id) }
    }

    @objc private func itemDidFinishPlaying() {
        DispatchQueue.main.async { self.next(triggeredByUser: false) }
    }

    private func clearPlaybackState() {
        teardownPlayer()
        isPlaying = false
        isBuffering = false
        currentSong = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func teardownPlayer() {
        artworkTask?.cancel()
        artworkTask = nil
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        player?.pause()
        player = nil
        playerItem = nil
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingPlaybackRate(0)
        saveState()
    }

    func resume() {
        guard let song = currentSong else { return }
        if player == nil {
            pendingSeekTime = resumeTime
            resumeTime = 0
            startPlayback(song: song)
        } else {
            player?.play()
            isPlaying = true
            updateNowPlayingPlaybackRate(1)
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func stop() {
        clearPlaybackState()
        queue = []
        currentIndex = 0
        playNextQueue = []
        userQueue = []
        resumeTime = 0
        shuffleSnapshot = nil
        isShuffled = false
        clearSavedState()
    }

    func playShuffled(songs: [Song]) {
        guard !songs.isEmpty else { return }
        let startIndex = Int.random(in: 0..<songs.count)
        play(songs: songs, startIndex: startIndex)
        toggleShuffle()
    }

    func toggleShuffle() {
        if isShuffled {
            guard let snap = shuffleSnapshot else {
                isShuffled = false
                saveState()
                return
            }

            let remainingInQueue: Set<String> = currentIndex + 1 < queue.count
                ? Set(queue[(currentIndex + 1)...].map { $0.id }) : []
            let remainingInPN = Set(playNextQueue.map { $0.id })
            let remainingInUQ = Set(userQueue.map { $0.id })
            let allRemaining = remainingInQueue.union(remainingInPN).union(remainingInUQ)

            let currentPlayingId = currentSong?.id
            let restoredQueueSuffix = snap.queue.filter { song in
                song.id != currentPlayingId && allRemaining.contains(song.id)
            }

            if let cid = currentPlayingId,
               let snapIdx = snap.queue.firstIndex(where: { $0.id == cid }) {
                queue = [snap.queue[snapIdx]] + restoredQueueSuffix
            } else {
                queue = (currentSong.map { [$0] } ?? []) + restoredQueueSuffix
            }
            currentIndex = 0

            let snapPNIds = Set(snap.playNextQueue.map { $0.id })
            let snapUQIds = Set(snap.userQueue.map { $0.id })
            let addedPN = playNextQueue.filter { !snapPNIds.contains($0.id) }
            let addedUQ = userQueue.filter { !snapUQIds.contains($0.id) }
            playNextQueue = snap.playNextQueue.filter { allRemaining.contains($0.id) } + addedPN
            userQueue = snap.userQueue.filter { allRemaining.contains($0.id) } + addedUQ

            shuffleSnapshot = nil
            isShuffled = false

        } else {
            shuffleSnapshot = ShuffleSnapshot(
                playNextQueue: playNextQueue,
                queue: queue,
                currentIndex: currentIndex,
                userQueue: userQueue
            )

            let upcoming = playNextQueue
                + Array(queue[(currentIndex + 1)...])
                + userQueue
            let shuffled = upcoming.shuffled()

            queue.replaceSubrange((currentIndex + 1)..., with: shuffled)
            playNextQueue = []
            userQueue = []
            isShuffled = true
        }
        saveState()
    }

    func next(triggeredByUser: Bool = false) {
        if repeatMode == .one && !triggeredByUser && playNextQueue.isEmpty {
            guard let song = currentSong else { return }
            startPlayback(song: song)
            saveState()
            return
        }

        if !playNextQueue.isEmpty {
            let song = playNextQueue.removeFirst()
            startPlayback(song: song)
        } else {
            let nextIndex = currentIndex + 1
            if nextIndex < queue.count {
                currentIndex = nextIndex
                startPlayback(song: queue[nextIndex])
            } else if !userQueue.isEmpty {
                let song = userQueue.removeFirst()
                queue.append(song)
                currentIndex = queue.count - 1
                startPlayback(song: song)
            } else if repeatMode == .all && !queue.isEmpty {
                if isShuffled { queue = queue.shuffled() }
                currentIndex = 0
                startPlayback(song: queue[0])
            } else {
                clearPlaybackState()
            }
        }
        saveState()
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
        } else {
            let prevIndex = currentIndex - 1
            guard prevIndex >= 0 else { return }
            currentIndex = prevIndex
            startPlayback(song: queue[prevIndex])
        }
        saveState()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        isSeeking = true
        let time = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isSeeking = false
                self?.updateNowPlayingTime(seconds)
            }
        }
    }

    func playFromQueue(index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        startPlayback(song: queue[index])
        saveState()
    }

    func jumpToPlayNext(at index: Int) {
        guard playNextQueue.indices.contains(index) else { return }
        let song = playNextQueue.remove(at: index)
        startPlayback(song: song)
        saveState()
    }

    func jumpToQueueTrack(at queueIndex: Int) {
        guard queue.indices.contains(queueIndex), queueIndex > currentIndex else { return }
        let song = queue.remove(at: queueIndex)
        let insertAt = currentIndex + 1
        queue.insert(song, at: insertAt)
        currentIndex = insertAt
        startPlayback(song: song)
        saveState()
    }

    func jumpToUserQueue(at index: Int) {
        guard userQueue.indices.contains(index) else { return }
        let song = userQueue.remove(at: index)
        let insertAt = currentIndex + 1
        queue.insert(song, at: insertAt)
        currentIndex = insertAt
        startPlayback(song: song)
        saveState()
    }

    private let maxQueueSize = 200

    func addPlayNext(_ song: Song) {
        shuffleSnapshot?.playNextQueue.append(song)
        if isShuffled {
            insertRandomlyInShuffledQueue(song)
        } else {
            playNextQueue.append(song)
        }
        saveState()
    }

    func addPlayNext(_ songs: [Song]) {
        shuffleSnapshot?.playNextQueue.append(contentsOf: songs)
        if isShuffled {
            songs.forEach { insertRandomlyInShuffledQueue($0) }
        } else {
            playNextQueue.append(contentsOf: songs)
        }
        saveState()
    }

    func removeFromPlayNextQueue(at index: Int) {
        guard playNextQueue.indices.contains(index) else { return }
        playNextQueue.remove(at: index)
        saveState()
    }

    func addToQueue(_ song: Song) {
        shuffleSnapshot?.userQueue.append(song)
        if isShuffled {
            insertRandomlyInShuffledQueue(song)
        } else {
            guard userQueue.count < maxQueueSize else { return }
            userQueue.append(song)
        }
        saveState()
    }

    func addToQueue(_ songs: [Song]) {
        shuffleSnapshot?.userQueue.append(contentsOf: songs)
        if isShuffled {
            songs.forEach { insertRandomlyInShuffledQueue($0) }
        } else {
            let slots = maxQueueSize - userQueue.count
            guard slots > 0 else { return }
            userQueue.append(contentsOf: songs.prefix(slots))
        }
        saveState()
    }

    private func insertRandomlyInShuffledQueue(_ song: Song) {
        let lo = currentIndex + 1
        let hi = queue.count
        let pos = lo <= hi ? Int.random(in: lo...hi) : hi
        queue.insert(song, at: pos)
    }

    func removeFromUserQueue(at index: Int) {
        guard userQueue.indices.contains(index) else { return }
        userQueue.remove(at: index)
        saveState()
    }

    func clearUserQueue() {
        userQueue = []
        saveState()
    }

    func removeFromPlayQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        saveState()
    }

    func clearUpcomingPlayQueue() {
        playNextQueue = []
        let start = currentIndex + 1
        guard start < queue.count else { return }
        queue.removeSubrange(start...)
        saveState()
    }

    func moveInPlayNextQueue(from source: IndexSet, to destination: Int) {
        playNextQueue.move(fromOffsets: source, toOffset: destination)
        saveState()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let offset = currentIndex + 1
        let absoluteSource = IndexSet(source.map { $0 + offset })
        let absoluteDestination = destination + offset
        queue.move(fromOffsets: absoluteSource, toOffset: absoluteDestination)
        saveState()
    }

    func moveInUserQueue(from source: IndexSet, to destination: Int) {
        userQueue.move(fromOffsets: source, toOffset: destination)
        saveState()
    }

    private func updateNowPlayingInfo(song: Song) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist ?? ""
        info[MPMediaItemPropertyAlbumTitle] = song.album ?? ""
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        if let d = song.duration { info[MPMediaItemPropertyPlaybackDuration] = Double(d) }

        if let artId = song.coverArt, let artURL = SubsonicAPIService.shared.coverArtURL(for: artId, size: 600) {
            artworkTask = URLSession.shared.dataTask(with: artURL) { [weak self] data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self?.currentArtwork = artwork
                DispatchQueue.main.async {
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
                    updated[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
            artworkTask?.resume()
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackRate(_ rate: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTime(_ time: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
