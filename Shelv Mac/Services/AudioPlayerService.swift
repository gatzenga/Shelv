import AVFoundation
import AppKit
import MediaPlayer
import Combine
import Network
import SwiftUI

private extension URL {
    func queryParam(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }
}

@MainActor
class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published var isPlaying: Bool = false
    @Published var isBuffering: Bool = false
    @Published var showBufferingIndicator: Bool = false
    @Published var currentSong: Song?
    @Published var queue: [QueueItem] = []
    @Published var playNextQueue: [Song] = []
    @Published var userQueue: [Song] = []
    @Published var currentIndex: Int = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 1.0 {
        didSet { engine.volume = volume }
    }
    @Published var isSeeking: Bool = false

    let timePublisher = PassthroughSubject<(time: Double, duration: Double), Never>()

    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var actualStreamFormat: ActualStreamFormat?
    @Published var artworkReloadToken: UUID = UUID()
    @Published var isNetworkAvailable: Bool = true

    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "shelv.desktop.netstatus", qos: .utility)
    private var networkResumeSong: Song?
    private var networkResumeTime: Double = 0

    private var formatProbeTask: Task<Void, Never>?

    func probeStreamFormat(songId: String, url: URL, duration: Double) {
        formatProbeTask?.cancel()
        if url.isFileURL {
            let path = url.path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            let bitrate: Int? = (size > 0 && duration > 1) ? Int(Double(size) * 8 / duration / 1000) : nil
            let codec = url.pathExtension.uppercased()
            actualStreamFormat = ActualStreamFormat(codecLabel: codec.isEmpty ? "?" : codec, bitrateKbps: bitrate)
            return
        }
        actualStreamFormat = nil
        let formatParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "format" })?.value
        let isTranscoded = (formatParam != nil && formatParam != "raw")
        formatProbeTask = Task { [weak self] in
            var probeURL = url
            if isTranscoded,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var items = components.queryItems ?? []
                items.append(URLQueryItem(name: "estimateContentLength", value: "true"))
                components.queryItems = items
                probeURL = components.url ?? url
            }
            var req = URLRequest(url: probeURL)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 8
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                guard !Task.isCancelled, let http = response as? HTTPURLResponse else { return }
                if http.statusCode != 200, isTranscoded {
                    print("[Transcoding] HEAD status \(http.statusCode)")
                    return
                }
                let codec = ActualStreamFormat.codecLabel(forMime: http.mimeType)
                let length = http.expectedContentLength
                var bitrate: Int? = nil
                if length > 0, duration > 1 {
                    bitrate = Int(Double(length) * 8 / duration / 1000)
                }
                await MainActor.run {
                    self?.actualStreamFormat = ActualStreamFormat(codecLabel: codec, bitrateKbps: bitrate)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if isTranscoded {
                    print("[Transcoding] HEAD failed (\(error.localizedDescription))")
                }
            }
        }
    }

    private var truthAlbumQueue: [Song] = []
    private var truthPlayNextQueue: [Song] = []
    private var truthUserQueue: [Song] = []
    private var isPlayingFromPlayNext = false

    private let engine = PlayerEngine()
    private var engineSubscriptions = Set<AnyCancellable>()
    private var bufferingShowTask: Task<Void, Never>?
    private var lastArtworkCoverArt: String? = nil
    private var gaplessPreloadTriggered = false
    private var gaplessPreloadSong: Song?
    private var gaplessPreloadURL: URL?
    private var prefetchScheduled = false
    private var prefetchedSongId: String? = nil
    private var isEngineLoaded = false
    private var currentStreamURL: URL?
    private var streamTimeOffset: Double = 0

    private var apiService: SubsonicAPIService { SubsonicAPIService.shared }

    private func resolveURL(songId: String) -> URL? {
        let serverId = AppState.shared.serverStore.activeServer?.stableId ?? ""
        if !serverId.isEmpty,
           let local = LocalDownloadIndex.shared.url(songId: songId, serverId: serverId) {
            return local
        }
        guard !OfflineModeService.shared.isOffline else { return nil }
        return apiService.streamURL(songId: songId)
    }

    private func isTranscodedRemote(_ url: URL) -> Bool {
        guard !url.isFileURL else { return false }
        let fmt = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "format" })?.value
        return fmt != nil && fmt != "raw"
    }


    private var currentArtwork: MPMediaItemArtwork?
    private var artworkLoadTask: Task<Void, Never>?
    private var hasScrobbledCurrent: Bool = false
    private var resumeTime: Double = 0

    private enum StateKey {
        static let queue                = "shelv_mac_queue"
        static let currentIndex         = "shelv_mac_currentIndex"
        static let playNextQueue        = "shelv_mac_playNextQueue"
        static let userQueue            = "shelv_mac_userQueue"
        static let currentTime          = "shelv_mac_currentTime"
        static let isShuffled           = "shelv_mac_isShuffled"
        static let repeatMode           = "shelv_mac_repeatMode"
        static let volume               = "shelv_mac_volume"
        static let truthAlbum           = "shelv_mac_truthAlbum"
        static let truthPlayNext        = "shelv_mac_truthPlayNext"
        static let truthUserQueue       = "shelv_mac_truthUserQueue"
        static let isPlayingFromPlayNext = "shelv_mac_isPlayingFromPlayNext"
    }

    private var willTerminateObserver: NSObjectProtocol?

    private init() {
        _ = NetworkStatus.shared
        setupNetworkMonitor()
        setupRemoteControls()
        setupEngine()
        Task { [weak self] in
            await NetworkStatus.shared.waitUntilReady()
            self?.restoreState()
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in self.saveState() }
        }
    }

    private func setupNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            // Synchroner Sync zu NetworkStatus.shared, damit ein anschliessender loadURL
            // (der die TranscodingPolicy → isOnWifi liest) den korrekten Wert sieht — auch wenn
            // der NetworkStatus-Monitor seinen eigenen Update noch nicht prozessiert hat.
            NetworkStatus.shared.update(from: path)
            let isAvailable = path.status == .satisfied
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isNetworkAvailable = isAvailable
                if isAvailable, let song = self.networkResumeSong {
                    self.networkResumeSong = nil
                    let t = self.networkResumeTime
                    self.networkResumeTime = 0
                    guard let url = self.resolveURL(songId: song.id) else { return }
                    self.loadURL(url, song: song, seekTo: t)
                }
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    deinit {
        networkMonitor.cancel()
        if let obs = willTerminateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func saveState() {
        let encoder = JSONEncoder()
        let defaults = UserDefaults.standard
        let songs = queue.map { $0.song }
        if let data = try? encoder.encode(songs) { defaults.set(data, forKey: StateKey.queue) }
        defaults.set(currentIndex, forKey: StateKey.currentIndex)
        if let data = try? encoder.encode(playNextQueue) { defaults.set(data, forKey: StateKey.playNextQueue) }
        if let data = try? encoder.encode(userQueue) { defaults.set(data, forKey: StateKey.userQueue) }
        defaults.set(currentTime, forKey: StateKey.currentTime)
        defaults.set(isShuffled, forKey: StateKey.isShuffled)
        defaults.set(repeatMode == .one ? "one" : repeatMode == .all ? "all" : "off", forKey: StateKey.repeatMode)
        defaults.set(Double(volume), forKey: StateKey.volume)
        defaults.set(isPlayingFromPlayNext, forKey: StateKey.isPlayingFromPlayNext)
        if let data = try? encoder.encode(truthAlbumQueue) { defaults.set(data, forKey: StateKey.truthAlbum) }
        if let data = try? encoder.encode(truthPlayNextQueue) { defaults.set(data, forKey: StateKey.truthPlayNext) }
        if let data = try? encoder.encode(truthUserQueue) { defaults.set(data, forKey: StateKey.truthUserQueue) }
    }

    private func clearSavedState() {
        let d = UserDefaults.standard
        [StateKey.queue, StateKey.currentIndex, StateKey.playNextQueue,
         StateKey.userQueue, StateKey.currentTime, StateKey.isShuffled,
         StateKey.repeatMode, StateKey.volume, StateKey.truthAlbum,
         StateKey.truthPlayNext, StateKey.truthUserQueue,
         StateKey.isPlayingFromPlayNext].forEach { d.removeObject(forKey: $0) }
    }

    private func restoreState() {
        let decoder = JSONDecoder()
        let defaults = UserDefaults.standard
        guard let queueData = defaults.data(forKey: StateKey.queue),
              let songs = try? decoder.decode([Song].self, from: queueData),
              !songs.isEmpty
        else { return }

        queue = songs.map { QueueItem(song: $0) }
        let idx = defaults.integer(forKey: StateKey.currentIndex)
        currentIndex = min(max(idx, 0), songs.count - 1)
        currentSong = songs[currentIndex]
        resumeTime = defaults.double(forKey: StateKey.currentTime)
        currentTime = resumeTime
        if let d = currentSong?.duration { duration = Double(d) }

        if let data = defaults.data(forKey: StateKey.playNextQueue),
           let pn = try? decoder.decode([Song].self, from: data) { playNextQueue = pn }
        if let data = defaults.data(forKey: StateKey.userQueue),
           let uq = try? decoder.decode([Song].self, from: data) { userQueue = uq }

        if let song = currentSong { updateNowPlayingInfo(song: song) }

        isShuffled = defaults.bool(forKey: StateKey.isShuffled)
        let repeatStr = defaults.string(forKey: StateKey.repeatMode) ?? "off"
        repeatMode = repeatStr == "one" ? .one : repeatStr == "all" ? .all : .off

        let savedVolume = defaults.double(forKey: StateKey.volume)
        volume = savedVolume > 0 ? Float(savedVolume) : 1.0

        isPlayingFromPlayNext = defaults.bool(forKey: StateKey.isPlayingFromPlayNext)

        if let data = defaults.data(forKey: StateKey.truthAlbum),
           let t = try? decoder.decode([Song].self, from: data) { truthAlbumQueue = t }
        if let data = defaults.data(forKey: StateKey.truthPlayNext),
           let t = try? decoder.decode([Song].self, from: data) { truthPlayNextQueue = t }
        if let data = defaults.data(forKey: StateKey.truthUserQueue),
           let t = try? decoder.decode([Song].self, from: data) { truthUserQueue = t }
    }

    func play(songs: [Song], startIndex: Int = 0) {
        isShuffled = false
        isPlayingFromPlayNext = false
        playNextQueue = []
        userQueue = []
        queue = songs.map { QueueItem(song: $0) }
        currentIndex = startIndex
        truthAlbumQueue = songs
        truthPlayNextQueue = []
        truthUserQueue = []
        playCurrent()
    }

    func playShuffled(songs: [Song]) {
        guard !songs.isEmpty else { return }
        let shuffled = songs.shuffled()
        let shuffledItems = shuffled.map { QueueItem(song: $0) }

        isShuffled = false
        isPlayingFromPlayNext = false
        playNextQueue = []
        userQueue = []
        queue = shuffledItems
        currentIndex = 0
        isShuffled = true
        truthAlbumQueue = songs
        truthPlayNextQueue = []
        truthUserQueue = []

        playCurrent()
    }

    func playSong(_ song: Song) {
        play(songs: [song], startIndex: 0)
    }

    #if DEBUG
    func loadDemoStandby() {
        engine.stop()
        isEngineLoaded = false
        isShuffled = false
        isPlayingFromPlayNext = false
        playNextQueue = []
        userQueue = []
        queue = DemoContent.playerQueue.map { QueueItem(song: $0) }
        currentIndex = DemoContent.playerCurrentIndex
        truthAlbumQueue = DemoContent.playerQueue
        truthPlayNextQueue = []
        truthUserQueue = []
        currentSong = DemoContent.playerSong
        currentTime = DemoContent.playerCurrentTime
        duration = DemoContent.playerDuration
        isPlaying = false
        actualStreamFormat = ActualStreamFormat(codecLabel: "MP3", bitrateKbps: 369)
    }
    #endif

    func playNext(triggeredByUser: Bool = true) {
        if !playNextQueue.isEmpty {
            let song = playNextQueue.removeFirst()
            if let i = truthPlayNextQueue.firstIndex(where: { $0.id == song.id }) {
                truthPlayNextQueue.remove(at: i)
            }
            isPlayingFromPlayNext = true
            if let prev = currentSong, prev.id != song.id {
                Task { await StreamCacheService.shared.cancel(songId: prev.id) }
            }
            currentSong = song
            hasScrobbledCurrent = false
            saveState()
            guard let url = resolveURL(songId: song.id) else { return }
            loadURL(url, song: song)
            return
        }
        isPlayingFromPlayNext = false

        guard !queue.isEmpty else {
            if !userQueue.isEmpty {
                let song = userQueue.removeFirst()
                let item = QueueItem(song: song)
                queue.append(item)
                currentIndex = 0
                playCurrent()
            } else {
                stop()
            }
            return
        }

        if repeatMode == .one && !triggeredByUser {
            playCurrent()
            return
        }

        if currentIndex < queue.count - 1 {
            currentIndex += 1
            playCurrent()
        } else if !userQueue.isEmpty {
            let song = userQueue.removeFirst()
            let item = QueueItem(song: song)
            queue.append(item)
            currentIndex = queue.count - 1
            playCurrent()
        } else if repeatMode == .all {
            let fullTruth = truthAlbumQueue + truthUserQueue
            truthAlbumQueue = fullTruth
            truthUserQueue = []
            truthPlayNextQueue = []
            let items = fullTruth.map { QueueItem(song: $0) }
            queue = isShuffled ? items.shuffled() : items
            playNextQueue = []
            userQueue = []
            currentIndex = 0
            if queue.isEmpty { stop() } else { playCurrent() }
        } else if repeatMode == .one {
            playCurrent()
        } else {
            stop()
        }
    }

    func playPrevious() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if isPlayingFromPlayNext {
            isPlayingFromPlayNext = false
            playCurrent()
            return
        }
        guard currentIndex > 0 else {
            seek(to: 0)
            return
        }
        currentIndex -= 1
        playCurrent()
    }

    func playQueue(at index: Int) {
        guard index >= 0 && index < queue.count else { return }
        isPlayingFromPlayNext = false
        currentIndex = index
        playCurrent()
    }

    func jumpToAlbumTrack(at index: Int) {
        guard queue.indices.contains(index), index > currentIndex else { return }
        let item = queue.remove(at: index)
        isPlayingFromPlayNext = true
        if let prev = currentSong, prev.id != item.song.id {
            Task { await StreamCacheService.shared.cancel(songId: prev.id) }
        }
        currentSong = item.song
        hasScrobbledCurrent = false
        guard let url = resolveURL(songId: item.song.id) else { return }
        loadURL(url, song: item.song)
        saveState()
    }

    func jumpToUserQueueTrack(at index: Int) {
        guard userQueue.indices.contains(index) else { return }
        let song = userQueue.remove(at: index)
        isPlayingFromPlayNext = true
        if let prev = currentSong, prev.id != song.id {
            Task { await StreamCacheService.shared.cancel(songId: prev.id) }
        }
        currentSong = song
        hasScrobbledCurrent = false
        guard let url = resolveURL(songId: song.id) else { return }
        loadURL(url, song: song)
        saveState()
    }

    func addPlayNext(_ song: Song) {
        truthPlayNextQueue.append(song)
        playNextQueue.append(song)
        saveState()
    }

    func addPlayNext(_ songs: [Song]) {
        truthPlayNextQueue.append(contentsOf: songs)
        playNextQueue.append(contentsOf: songs)
        saveState()
    }

    private func insertRandomlyInShuffledQueue(_ song: Song) {
        let lo = currentIndex + 1
        let hi = queue.count
        let pos = lo <= hi ? Int.random(in: lo...hi) : hi
        queue.insert(QueueItem(song: song), at: pos)
    }

    func removeFromPlayNextQueue(at index: Int) {
        guard playNextQueue.indices.contains(index) else { return }
        let songId = playNextQueue[index].id
        playNextQueue.remove(at: index)
        if let i = truthPlayNextQueue.firstIndex(where: { $0.id == songId }) {
            truthPlayNextQueue.remove(at: i)
        }
        saveState()
    }

    func moveInPlayNextQueue(from: IndexSet, to: Int) {
        playNextQueue.move(fromOffsets: from, toOffset: to)
        truthPlayNextQueue = playNextQueue
        saveState()
    }

    func jumpToPlayNextTrack(at index: Int) {
        guard playNextQueue.indices.contains(index) else { return }
        let song = playNextQueue.remove(at: index)
        if let i = truthPlayNextQueue.firstIndex(where: { $0.id == song.id }) {
            truthPlayNextQueue.remove(at: i)
        }
        isPlayingFromPlayNext = true
        if let prev = currentSong, prev.id != song.id {
            Task { await StreamCacheService.shared.cancel(songId: prev.id) }
        }
        currentSong = song
        hasScrobbledCurrent = false
        guard let url = resolveURL(songId: song.id) else { return }
        loadURL(url, song: song)
        saveState()
    }

    func addToUserQueue(_ song: Song) {
        truthUserQueue.append(song)
        if isShuffled {
            insertRandomlyInShuffledQueue(song)
        } else {
            userQueue.append(song)
        }
        saveState()
    }

    func addToUserQueue(_ songs: [Song]) {
        truthUserQueue.append(contentsOf: songs)
        if isShuffled {
            songs.forEach { insertRandomlyInShuffledQueue($0) }
        } else {
            userQueue.append(contentsOf: songs)
        }
        saveState()
    }

    func removeFromUserQueue(at index: Int) {
        guard userQueue.indices.contains(index) else { return }
        let songId = userQueue[index].id
        userQueue.remove(at: index)
        if let i = truthUserQueue.firstIndex(where: { $0.id == songId }) {
            truthUserQueue.remove(at: i)
        }
        saveState()
    }

    func moveInUserQueue(from: IndexSet, to: Int) {
        let oldTruth = truthUserQueue
        userQueue.move(fromOffsets: from, toOffset: to)
        truthUserQueue = Self.rebuildTruthPreservingTapped(
            oldTruth: oldTruth, newVisible: userQueue
        )
        saveState()
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        let songId = queue[index].song.id
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        if let i = truthAlbumQueue.firstIndex(where: { $0.id == songId }) {
            truthAlbumQueue.remove(at: i)
        } else if let i = truthUserQueue.firstIndex(where: { $0.id == songId }) {
            truthUserQueue.remove(at: i)
        }
        saveState()
    }

    func moveInAlbumQueue(from: IndexSet, to: Int) {
        let oldAlbumTruth = truthAlbumQueue
        let oldUserTruth = truthUserQueue
        let offset = currentIndex + 1
        var adjustedFrom = IndexSet()
        for i in from { adjustedFrom.insert(i + offset) }
        queue.move(fromOffsets: adjustedFrom, toOffset: to + offset)
        if !isShuffled {
            let visibleSongs = queue.map { $0.song }
            truthAlbumQueue = Self.rebuildTruthPreservingTapped(
                oldTruth: oldAlbumTruth, newVisible: visibleSongs
            )
            let visibleIds = Set(visibleSongs.map { $0.id })
            truthUserQueue = oldUserTruth.filter { !visibleIds.contains($0.id) }
        }
        saveState()
    }

    private static func rebuildTruthPreservingTapped(oldTruth: [Song], newVisible: [Song]) -> [Song] {
        let visibleIds = Set(newVisible.map { $0.id })
        var result = newVisible
        for index in 0..<oldTruth.count {
            let song = oldTruth[index]
            if visibleIds.contains(song.id) { continue }
            if index > 0 {
                let leftAnchorId = oldTruth[index - 1].id
                if let anchorIdx = result.firstIndex(where: { $0.id == leftAnchorId }) {
                    result.insert(song, at: anchorIdx + 1)
                    continue
                }
            }
            result.insert(song, at: 0)
        }
        return result
    }

    func clearAllQueues() {
        playNextQueue = []
        userQueue = []
        let removeFrom = currentIndex + 1
        if removeFrom < queue.count {
            queue.removeSubrange(removeFrom...)
        }
        let currentId = currentSong?.id
        truthPlayNextQueue = []
        truthUserQueue = []
        if let cur = currentId {
            truthAlbumQueue = truthAlbumQueue.filter { $0.id == cur }
        } else {
            truthAlbumQueue = []
        }
        saveState()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        networkResumeSong = nil
        engine.pause()
        isPlaying = false
        isBuffering = false
        MPNowPlayingInfoCenter.default().playbackState = .paused
        saveState()
    }

    func resume() {
        guard let song = currentSong else { return }
        if !isEngineLoaded {
            let seek = resumeTime
            resumeTime = 0
            guard let url = resolveURL(songId: song.id) else { return }
            loadURL(url, song: song, seekTo: seek)
        } else {
            engine.resume()
            isPlaying = true
            MPNowPlayingInfoCenter.default().playbackState = .playing
        }
    }

    func stop() {
        networkResumeSong = nil
        networkResumeTime = 0
        engine.stop()
        isEngineLoaded = false
        gaplessPreloadTriggered = false
        gaplessPreloadSong = nil
        gaplessPreloadURL = nil
        prefetchScheduled = false
        prefetchedSongId = nil
        currentStreamURL = nil
        streamTimeOffset = 0
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        currentSong = nil
        isPlaying = false
        isBuffering = false
        isPlayingFromPlayNext = false
        currentTime = 0
        duration = 0
        queue = []
        currentIndex = 0
        playNextQueue = []
        userQueue = []
        truthAlbumQueue = []
        truthPlayNextQueue = []
        truthUserQueue = []
        isShuffled = false
        updateNowPlayingInfo()
        clearSavedState()
    }

    func toggleShuffle() {
        if isShuffled {
            let remainingAlbum: Set<String> = Set(queue[(min(currentIndex + 1, queue.count))...].map { $0.song.id })
            let remainingPN = Set(playNextQueue.map { $0.id })
            let remainingUQ = Set(userQueue.map { $0.id })
            let allRemaining = remainingAlbum.union(remainingPN).union(remainingUQ)
            let currentId = currentSong?.id

            let restoredAlbum = truthAlbumQueue.filter {
                $0.id != currentId && allRemaining.contains($0.id)
            }
            if let cur = currentSong {
                queue = [QueueItem(song: cur)] + restoredAlbum.map { QueueItem(song: $0) }
            } else {
                queue = restoredAlbum.map { QueueItem(song: $0) }
            }
            currentIndex = 0
            playNextQueue = truthPlayNextQueue.filter {
                $0.id != currentId && allRemaining.contains($0.id)
            }
            userQueue = truthUserQueue.filter {
                $0.id != currentId && allRemaining.contains($0.id)
            }
            isShuffled = false
        } else {
            let upcoming = Array(queue[(currentIndex + 1)...])
                + userQueue.map { QueueItem(song: $0) }
            queue.replaceSubrange((currentIndex + 1)..., with: upcoming.shuffled())
            userQueue = []
            isShuffled = true
        }
        saveState()
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.nextMode
    }

    func seek(to time: Double) {
        isSeeking = true
        currentTime = time
        let buffered = engine.isPositionBuffered(time)
        let shouldPauseAndWait = !buffered && self.isPlaying
        if shouldPauseAndWait { isBuffering = true }
        engine.seek(to: time, pauseUntilBuffered: shouldPauseAndWait) { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    if finished { self.currentTime = time }
                    self.isSeeking = false
                }
            }
        }
    }

    func setCurrentSongStarred(_ starred: Bool) {
        guard var song = currentSong else { return }
        song.starred = starred ? Date() : nil
        currentSong = song
        if currentIndex < queue.count {
            queue[currentIndex].song.starred = song.starred
        }
        updateNowPlayingInfo()
    }

    private func playCurrent() {
        guard currentIndex >= 0 && currentIndex < queue.count else { return }
        startPlayback(queueItem: queue[currentIndex])
        saveState()
    }

    private func startPlayback(queueItem: QueueItem) {
        let song = queueItem.song
        if let prev = currentSong, prev.id != song.id {
            Task { await StreamCacheService.shared.cancel(songId: prev.id) }
        }
        currentSong = song
        applyReplayGain(for: song)
        hasScrobbledCurrent = false
        guard let url = resolveURL(songId: song.id) else {
            if OfflineModeService.shared.isOffline {
                NotificationCenter.default.post(name: .showToast, object: String(localized: "not_available_offline"))
            }
            return
        }
        loadURL(url, song: song)
    }

    private func loadURL(_ url: URL, song: Song, seekTo: Double = 0) {
        networkResumeSong = nil
        currentStreamURL = url
        streamTimeOffset = 0
        gaplessPreloadTriggered = false
        gaplessPreloadSong = nil
        gaplessPreloadURL = nil
        prefetchScheduled = false
        formatProbeTask?.cancel()
        actualStreamFormat = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        isPlaying = true
        if song.coverArt != lastArtworkCoverArt {
            artworkReloadToken = UUID()
            lastArtworkCoverArt = song.coverArt
        }
        isEngineLoaded = false
        isBuffering = false
        isBuffering = true
        isSeeking = false
        currentTime = 0
        duration = Double(song.duration ?? 0)

        if let prefId = prefetchedSongId, prefId != song.id {
            Task { await StreamCacheService.shared.cancel(songId: prefId) }
        }
        prefetchedSongId = nil

        if isTranscodedRemote(url), let fmt = TranscodingPolicy.currentStreamFormat() {
            engine.stop()
            let songId = song.id
            actualStreamFormat = ActualStreamFormat(
                codecLabel: fmt.codec.rawValue.uppercased(),
                bitrateKbps: fmt.bitrate
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                await StreamCacheService.shared.prefetch(
                    songId: songId,
                    url: url,
                    codec: fmt.codec.rawValue,
                    bitrate: fmt.bitrate,
                    songTitle: song.title
                )
                let deadline = Date().addingTimeInterval(60)
                repeat {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard self.currentSong?.id == songId else { return }
                    if let local = await StreamCacheService.shared.localURL(for: songId) {
                        let asset = AVURLAsset(url: local, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                        let cmTime = try? await asset.load(.duration)
                        guard self.currentSong?.id == songId, !self.isEngineLoaded else { return }
                        let precise = cmTime.flatMap { $0.isValid && !$0.isIndefinite ? CMTimeGetSeconds($0) : nil }
                        let resolvedDuration = (precise ?? 0) > 0 ? precise! : Double(song.duration ?? 0)
                        self.currentStreamURL = local
                        self.engine.play(url: local)
                        if !self.isPlaying { self.engine.pause() }
                        self.engine.trustedDuration = resolvedDuration
                        self.duration = resolvedDuration
                        if seekTo > 0 { self.engine.seek(to: seekTo) }
                        self.isEngineLoaded = true
                        self.isBuffering = false
                        return
                    }
                } while Date() < deadline
                if self.currentSong?.id == songId, !self.isEngineLoaded,
                   let rawURL = self.apiService.rawStreamURL(songId: songId) {
                    self.currentStreamURL = rawURL
                    self.probeStreamFormat(songId: songId, url: rawURL, duration: Double(song.duration ?? 0))
                    self.engine.play(url: rawURL)
                    if !self.isPlaying { self.engine.pause() }
                    self.engine.trustedDuration = Double(song.duration ?? 0)
                    if seekTo > 0 { self.engine.seek(to: seekTo) }
                    self.isEngineLoaded = true
                    self.isBuffering = false
                }
            }
        } else if !url.isFileURL, streamPreCacheEnabled {
            // Original-Remote-Stream mit Pre-Cache → erst vollständig laden, dann lokal abspielen
            engine.stop()
            let songId = song.id
            let suffix = song.suffix?.lowercased() ?? "audio"
            Task { @MainActor [weak self] in
                guard let self else { return }
                await StreamCacheService.shared.prefetch(
                    songId: songId,
                    url: url,
                    codec: suffix,
                    bitrate: 0,
                    songTitle: song.title
                )
                let deadline = Date().addingTimeInterval(60)
                repeat {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard self.currentSong?.id == songId else { return }
                    if let local = await StreamCacheService.shared.localURL(for: songId) {
                        let asset = AVURLAsset(url: local, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                        let cmTime = try? await asset.load(.duration)
                        guard self.currentSong?.id == songId, !self.isEngineLoaded else { return }
                        let precise = cmTime.flatMap { $0.isValid && !$0.isIndefinite ? CMTimeGetSeconds($0) : nil }
                        let resolvedDuration = (precise ?? 0) > 0 ? precise! : Double(song.duration ?? 0)
                        self.currentStreamURL = local
                        self.probeStreamFormat(songId: songId, url: local, duration: resolvedDuration)
                        self.engine.play(url: local)
                        if !self.isPlaying { self.engine.pause() }
                        self.engine.trustedDuration = resolvedDuration
                        self.duration = resolvedDuration
                        if seekTo > 0 { self.engine.seek(to: seekTo) }
                        self.isEngineLoaded = true
                        self.isBuffering = false
                        return
                    }
                } while Date() < deadline
                // Timeout-Fallback: direkt streamen
                if self.currentSong?.id == songId, !self.isEngineLoaded {
                    self.probeStreamFormat(songId: songId, url: url, duration: Double(song.duration ?? 0))
                    self.engine.play(url: url)
                    if !self.isPlaying { self.engine.pause() }
                    self.engine.trustedDuration = Double(song.duration ?? 0)
                    if seekTo > 0 { self.engine.seek(to: seekTo) }
                    self.isEngineLoaded = true
                    self.isBuffering = false
                }
            }
        } else {
            probeStreamFormat(songId: song.id, url: url, duration: Double(song.duration ?? 0))
            engine.play(url: url)
            engine.trustedDuration = Double(song.duration ?? 0)
            isEngineLoaded = true
            if seekTo > 0 { engine.seek(to: seekTo) }
        }

        currentArtwork = nil
        loadArtworkAsync(for: song)
        updateNowPlayingInfo(song: song)
        Task { try? await apiService.scrobble(songId: song.id, submission: false) }
    }

    // MARK: - Engine setup

    private func setupEngine() {
        engine.onTrackFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.gaplessPreloadTriggered, self.gaplessPreloadURL != nil, let song = self.gaplessPreloadSong {
                    self.gaplessPreloadTriggered = false
                    self.gaplessPreloadSong = nil
                    self.gaplessPreloadURL = nil

                    guard self.peekNextSong()?.id == song.id else {
                        self.playNext(triggeredByUser: false)
                        return
                    }

                    self.advanceQueueState()
                    self.currentSong = song
                    self.applyReplayGain(for: song)
                    self.hasScrobbledCurrent = false
                    self.currentTime = 0
                    self.isSeeking = false
                    self.streamTimeOffset = 0
                    self.prefetchScheduled = false
                    self.prefetchedSongId = nil
                    if let d = song.duration { self.duration = Double(d) }
                    self.engine.trustedDuration = Double(song.duration ?? 0)
                    self.isEngineLoaded = true
                    self.isBuffering = false
                    self.updateNowPlayingInfo(song: song)
                    self.loadArtworkAsync(for: song)
                    if let url = self.resolveURL(songId: song.id) {
                        self.currentStreamURL = url
                        self.probeStreamFormat(songId: song.id, url: url, duration: Double(song.duration ?? 0))
                    }
                    Task { try? await self.apiService.scrobble(songId: song.id, submission: false) }
                    self.saveState()
                } else {
                    self.gaplessPreloadTriggered = false
                    self.gaplessPreloadSong = nil
                    self.gaplessPreloadURL = nil
                    self.playNext(triggeredByUser: false)
                }
            }
        }

        engine.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self, self.isEngineLoaded, !self.isSeeking else { return }
                let adjusted = time + self.streamTimeOffset
                self.currentTime = adjusted
                self.timePublisher.send((time: adjusted, duration: self.duration))
                self.updateNowPlayingInfo()
                if let songId = self.currentSong?.id {
                    self.scrobbleIfNeeded(songId: songId)
                }
                self.checkGaplessTrigger(currentTime: adjusted)
            }
            .store(in: &engineSubscriptions)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in
                guard let self, d > 0 else { return }
                self.duration = d
                self.timePublisher.send((time: self.currentTime, duration: d))
            }
            .store(in: &engineSubscriptions)

        engine.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self, playing else { return }
                MPNowPlayingInfoCenter.default().playbackState = .playing
            }
            .store(in: &engineSubscriptions)

        engine.$isWaiting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] waiting in
                guard let self, self.isEngineLoaded, self.isPlaying else { return }
                self.isBuffering = waiting
            }
            .store(in: &engineSubscriptions)

        engine.onPlaybackFailed = { [weak self] in
            guard let self else { return }
            self.isEngineLoaded = false
            guard self.isPlaying else { return }
            self.networkResumeSong = self.currentSong
            self.networkResumeTime = self.currentTime
            self.resumeTime = self.currentTime
            self.isBuffering = true
        }

        $isBuffering
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isBuf in
                guard let self else { return }
                self.bufferingShowTask?.cancel()
                if isBuf {
                    self.bufferingShowTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, let self, self.isBuffering else { return }
                        self.showBufferingIndicator = true
                    }
                } else {
                    self.showBufferingIndicator = false
                }
            }
            .store(in: &engineSubscriptions)
    }

    // MARK: - Gapless

    private var gaplessEnabled: Bool {
        UserDefaults.standard.bool(forKey: "gaplessEnabled")
    }

    private var streamPreCacheEnabled: Bool {
        UserDefaults.standard.bool(forKey: "streamPreCacheEnabled")
    }

    private func checkGaplessTrigger(currentTime: Double) {
        guard duration > 11 else { return }
        guard !(repeatMode == .one && playNextQueue.isEmpty) else { return }
        guard let nextSong = peekNextSong() else { return }

        if currentTime >= 5, !prefetchScheduled,
           let nextURL = resolveURL(songId: nextSong.id) {
            if isTranscodedRemote(nextURL), let fmt = TranscodingPolicy.currentStreamFormat() {
                prefetchScheduled = true
                prefetchedSongId = nextSong.id
                Task {
                    await StreamCacheService.shared.prefetch(
                        songId: nextSong.id,
                        url: nextURL,
                        codec: fmt.codec.rawValue,
                        bitrate: fmt.bitrate,
                        songTitle: nextSong.title
                    )
                }
            } else if !nextURL.isFileURL, streamPreCacheEnabled {
                prefetchScheduled = true
                prefetchedSongId = nextSong.id
                let suffix = nextSong.suffix?.lowercased() ?? "audio"
                Task {
                    await StreamCacheService.shared.prefetch(
                        songId: nextSong.id,
                        url: nextURL,
                        codec: suffix,
                        bitrate: 0,
                        songTitle: nextSong.title
                    )
                }
            }
        }

        guard !gaplessPreloadTriggered else { return }
        guard gaplessEnabled else { return }
        let preloadAt = duration - 10
        guard currentTime >= preloadAt else { return }
        guard let url = resolveURL(songId: nextSong.id) else { return }

        if isTranscodedRemote(url) {
            gaplessPreloadSong = nextSong
            gaplessPreloadTriggered = true
            let songId = nextSong.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(8)
                repeat {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard self.gaplessPreloadSong?.id == songId else { return }
                    if let local = await StreamCacheService.shared.localURL(for: songId) {
                        self.gaplessPreloadURL = local
                        self.engine.preloadForGapless(url: local)
                        return
                    }
                } while Date() < deadline
                if self.gaplessPreloadSong?.id == songId {
                    self.gaplessPreloadTriggered = false
                    self.gaplessPreloadSong = nil
                }
            }
        } else if !url.isFileURL, streamPreCacheEnabled {
            // Original-Remote-Stream — auf lokale Datei warten (Prefetch läuft seit 5s-Marker)
            gaplessPreloadSong = nextSong
            gaplessPreloadTriggered = true
            let songId = nextSong.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    if let local = await StreamCacheService.shared.localURL(for: songId) {
                        guard self.gaplessPreloadSong?.id == songId else { return }
                        self.gaplessPreloadURL = local
                        self.engine.preloadForGapless(url: local)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if self.gaplessPreloadSong?.id == songId {
                    self.gaplessPreloadTriggered = false
                    self.gaplessPreloadSong = nil
                }
            }
        } else {
            gaplessPreloadSong = nextSong
            gaplessPreloadURL = url
            gaplessPreloadTriggered = true
            engine.preloadForGapless(url: url)
        }
    }

    private func peekNextSong() -> Song? {
        if !playNextQueue.isEmpty { return playNextQueue.first }
        if repeatMode == .one { return nil }
        if currentIndex + 1 < queue.count {
            return queue[currentIndex + 1].song
        }
        if !userQueue.isEmpty {
            return userQueue.first
        }
        return nil
    }

    private func advanceQueueState() {
        if !playNextQueue.isEmpty {
            playNextQueue.removeFirst()
            isPlayingFromPlayNext = true
        } else {
            isPlayingFromPlayNext = false
            switch repeatMode {
            case .one: break
            case .all:
                guard !queue.isEmpty else { return }
                currentIndex = (currentIndex + 1) % queue.count
            case .off:
                if currentIndex + 1 < queue.count {
                    currentIndex += 1
                } else if !userQueue.isEmpty {
                    let song = userQueue.removeFirst()
                    queue.append(QueueItem(song: song))
                    currentIndex = queue.count - 1
                }
            }
        }
    }

    // MARK: - Scrobble

    private func scrobbleIfNeeded(songId: String) {
        guard !hasScrobbledCurrent else { return }
        let pct = Double(UserDefaults.standard.integer(forKey: "recapThreshold"))
        let fraction = pct > 0 ? pct / 100.0 : 0.3
        let threshold = duration * fraction
        guard threshold > 0, currentTime >= threshold else { return }
        hasScrobbledCurrent = true
        let serverId = AppState.shared.serverStore.activeServer?.stableId ?? ""
        let scrobbleAt = Date().timeIntervalSince1970
        Task {
            do {
                try await apiService.scrobble(songId: songId, submission: true, playedAt: scrobbleAt)
            } catch {
                guard !serverId.isEmpty else { return }
                await PlayLogService.shared.addPendingScrobble(
                    songId: songId, serverId: serverId, playedAt: scrobbleAt
                )
            }
        }
    }

    // MARK: - Artwork

    private func loadArtworkAsync(for song: Song) {
        artworkLoadTask?.cancel()
        guard let coverID = song.coverArt,
              let artURL = apiService.coverArtURL(id: coverID, size: 600) else { return }

        artworkLoadTask = Task.detached(priority: .utility) { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: artURL),
                  !Task.isCancelled,
                  let nsImage = NSImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { _ in nsImage }
            await MainActor.run { [weak self] in
                self?.currentArtwork = artwork
                self?.updateNowPlayingInfo()
            }
        }
    }

    // MARK: - Remote Controls

    private func setupRemoteControls() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                Task { @MainActor in self?.seek(to: e.positionTime) }
            }
            return .success
        }
    }

    // MARK: - Now Playing

    private func updateNowPlayingInfo(song: Song? = nil) {
        let s = song ?? currentSong
        guard let s else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.title,
            MPMediaItemPropertyArtist: s.artist ?? "",
            MPMediaItemPropertyAlbumTitle: s.album ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue as NSNumber
        ]

        if let artwork = currentArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func applyReplayGain(for song: Song) {
        let enabled = UserDefaults.standard.bool(forKey: "replayGainEnabled")
        guard enabled, let rg = song.replayGain else {
            engine.volume = 1.0
            return
        }
        let useTrack = (UserDefaults.standard.string(forKey: "replayGainMode") ?? "track") == "track"
        let gain: Float? = useTrack ? (rg.trackGain ?? rg.albumGain) : (rg.albumGain ?? rg.trackGain)
        guard let gain else {
            engine.volume = 1.0
            return
        }
        let linear = pow(10.0, gain / 20.0)
        let peak: Float? = useTrack ? rg.trackPeak : rg.albumPeak
        let vol: Float = peak.map { $0 > 0 ? min(linear, 1.0 / $0) : linear } ?? min(linear, 1.0)
        engine.volume = vol
    }
}
