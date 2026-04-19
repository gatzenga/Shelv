import AVFoundation
import MediaPlayer
import Combine
import UIKit
import SwiftUI
import Network

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
    @Published var isNetworkAvailable: Bool = true
    @Published var currentSong: Song?
    @Published var queue: [Song] = []
    @Published var currentIndex: Int = 0
    @Published var playNextQueue: [Song] = []
    @Published var userQueue: [Song] = []
    var currentTime: Double = 0
    var duration: Double = 0
    let timePublisher = PassthroughSubject<(time: Double, duration: Double), Never>()
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

    private let engine = CrossfadeEngine()
    private var engineSubscriptions = Set<AnyCancellable>()
    private var crossfadeTriggered = false
    private var crossfadeSeekSuppressed = false
    private var isEngineLoaded = false
    private var currentArtwork: MPMediaItemArtwork?
    private var artworkTask: URLSessionDataTask?

    private var networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "shelv.network", qos: .utility)

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
        setupEngine()
        setupRemoteControls()
        setupRouteObserver()
        setupNetworkMonitor()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        restoreState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        networkMonitor.cancel()
    }

    private func setupNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isNetworkAvailable = path.status == .satisfied
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
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

        if let song = currentSong { updateNowPlayingInfo(song: song) }
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetoothHFP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioSession] Failed to activate: \(error)")
        }
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

        crossfadeTriggered = false
        crossfadeSeekSuppressed = false
        currentSong = song
        isBuffering = true
        currentTime = 0
        if let d = song.duration { duration = Double(d) }

        let seekTo = pendingSeekTime
        pendingSeekTime = 0

        engine.play(url: url)
        if seekTo > 0 { engine.seek(to: seekTo) }
        isEngineLoaded = true

        MPNowPlayingInfoCenter.default().playbackState = .playing
        updateNowPlayingInfo(song: song)
        let scrobbleSongId = song.id
        let scrobbleServerId = SubsonicAPIService.shared.activeServer?.stableId ?? ""
        let scrobbleAt = Date().timeIntervalSince1970
        Task {
            do {
                try await SubsonicAPIService.shared.scrobble(songId: scrobbleSongId, playedAt: scrobbleAt)
            } catch {
                guard !scrobbleServerId.isEmpty else { return }
                await PlayLogService.shared.addPendingScrobble(
                    songId: scrobbleSongId, serverId: scrobbleServerId, playedAt: scrobbleAt
                )
            }
        }
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
        engine.stop()
        isEngineLoaded = false
        crossfadeTriggered = false
        crossfadeSeekSuppressed = false
    }

    func pause() {
        engine.pause()
        isPlaying = false
        updateNowPlayingPlaybackRate(0)
        MPNowPlayingInfoCenter.default().playbackState = .paused
        saveState()
    }

    func resume() {
        guard let song = currentSong else { return }
        if !isEngineLoaded {
            pendingSeekTime = resumeTime
            resumeTime = 0
            startPlayback(song: song)
        } else {
            engine.resume()
            isPlaying = true
            updateNowPlayingPlaybackRate(1)
            MPNowPlayingInfoCenter.default().playbackState = .playing
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
        let shuffled = songs.shuffled()

        playNextQueue = []
        userQueue = []
        queue = shuffled
        currentIndex = 0
        isShuffled = true

        shuffleSnapshot = ShuffleSnapshot(
            playNextQueue: [],
            queue: shuffled,
            currentIndex: 0,
            userQueue: []
        )

        resumeTime = 0
        startPlayback(song: shuffled[0])
        saveState()
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
                + (currentIndex + 1 < queue.count ? Array(queue[(currentIndex + 1)...]) : [])
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
            saveState()
            return
        }
        let prevIndex = currentIndex - 1
        guard prevIndex >= 0 else { return }
        currentIndex = prevIndex
        startPlayback(song: queue[prevIndex])
        saveState()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        isSeeking = true
        updateNowPlayingTime(seconds)
        crossfadeSeekSuppressed = crossfadeEnabled && duration > 0 && seconds >= duration - crossfadeDuration
        engine.seek(to: seconds) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isSeeking = false
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
            userQueue.append(song)
        }
        saveState()
    }

    func addToQueue(_ songs: [Song]) {
        shuffleSnapshot?.userQueue.append(contentsOf: songs)
        if isShuffled {
            songs.forEach { insertRandomlyInShuffledQueue($0) }
        } else {
            userQueue.append(contentsOf: songs)
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
        if start < queue.count {
            queue.removeSubrange(start...)
        }
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

    private var crossfadeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "crossfadeEnabled")
    }

    private var crossfadeDuration: Double {
        let v = UserDefaults.standard.integer(forKey: "crossfadeDuration")
        return v >= 1 ? Double(v) : 5
    }

    private func setupEngine() {
        engine.onTrackFinished = { [weak self] in
            guard let self else { return }
            if self.crossfadeTriggered {
                self.crossfadeTriggered = false
            } else {
                self.next(triggeredByUser: false)
            }
        }

        engine.$currentTime
            .sink { [weak self] time in
                guard let self, !self.isSeeking else { return }
                self.currentTime = time
                self.timePublisher.send((time: time, duration: self.duration))
                self.updateNowPlayingTime(time)
                if !self.crossfadeTriggered {
                    self.checkCrossfadeTrigger(currentTime: time)
                }
            }
            .store(in: &engineSubscriptions)

        engine.$duration
            .sink { [weak self] d in
                guard let self, d > 0 else { return }
                self.duration = d
                self.timePublisher.send((time: self.currentTime, duration: d))
            }
            .store(in: &engineSubscriptions)

        engine.$isPlaying
            .sink { [weak self] playing in
                guard let self else { return }
                if playing { self.isBuffering = false }
                self.isPlaying = playing
            }
            .store(in: &engineSubscriptions)
    }

    private func peekNextSong() -> Song? {
        if !playNextQueue.isEmpty { return playNextQueue[0] }
        let nextIndex = currentIndex + 1
        if nextIndex < queue.count { return queue[nextIndex] }
        if !userQueue.isEmpty { return userQueue[0] }
        if repeatMode == .all && !queue.isEmpty && !isShuffled { return queue[0] }
        return nil
    }

    private func advanceQueueState() {
        if !playNextQueue.isEmpty {
            playNextQueue.removeFirst()
        } else {
            let nextIndex = currentIndex + 1
            if nextIndex < queue.count {
                currentIndex = nextIndex
            } else if !userQueue.isEmpty {
                let song = userQueue.removeFirst()
                queue.append(song)
                currentIndex = queue.count - 1
            } else if repeatMode == .all && !queue.isEmpty {
                currentIndex = 0
            }
        }
    }

    private func crossfadeToSong(_ song: Song) {
        guard let url = SubsonicAPIService.shared.streamURL(for: song.id) else { return }

        engine.crossfadeDuration = crossfadeDuration
        engine.triggerCrossfade(nextURL: url)

        crossfadeTriggered = true
        currentSong = song
        currentTime = 0
        isEngineLoaded = true
        if let d = song.duration { duration = Double(d) }

        updateNowPlayingInfo(song: song)
        MPNowPlayingInfoCenter.default().playbackState = .playing
        let scrobbleSongId = song.id
        let scrobbleServerId = SubsonicAPIService.shared.activeServer?.stableId ?? ""
        let scrobbleAt = Date().timeIntervalSince1970
        Task {
            do {
                try await SubsonicAPIService.shared.scrobble(songId: scrobbleSongId, playedAt: scrobbleAt)
            } catch {
                guard !scrobbleServerId.isEmpty else { return }
                await PlayLogService.shared.addPendingScrobble(
                    songId: scrobbleSongId, serverId: scrobbleServerId, playedAt: scrobbleAt
                )
            }
        }
    }

    private func checkCrossfadeTrigger(currentTime: Double) {
        guard crossfadeEnabled, !crossfadeTriggered, !crossfadeSeekSuppressed, duration > 1 else { return }
        guard crossfadeDuration < duration else { return }

        let triggerAt = duration - crossfadeDuration
        guard triggerAt >= 1.0 else { return }
        guard currentTime >= triggerAt else { return }
        guard !(repeatMode == .one && playNextQueue.isEmpty) else { return }
        guard let nextSong = peekNextSong() else { return }

        crossfadeTriggered = true
        advanceQueueState()
        crossfadeToSong(nextSong)
        saveState()
    }

    private func updateNowPlayingInfo(song: Song) {
        artworkTask?.cancel()
        artworkTask = nil
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
