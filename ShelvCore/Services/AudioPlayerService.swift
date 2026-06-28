import AVFoundation
import MediaPlayer
import Combine
#if canImport(UIKit)
import UIKit      // iOS + tvOS
#else
import AppKit     // macOS
#endif
import SwiftUI
import Network

extension URL {
    func queryParam(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }
}

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
    @Published var showBufferingIndicator: Bool = false
    @Published var isNetworkAvailable: Bool = true
    @Published var currentSong: Song? {
        didSet {
            // Endlos-Modus: bei JEDEM Songwechsel (Skip, natürliches Ende, Gapless-Übergang)
            // sicherstellen, dass wieder genau einer voraus bereitliegt. Deckt alle Pfade ab —
            // auch im Hintergrund, da dort die Wiedergabe weiterläuft.
            if currentSong?.id != oldValue?.id {
                // Der zuvor vorgemerkte Infinity-Song ist jetzt nicht mehr "voraus" (gerade
                // current geworden oder weggeskippt) → Marker zurücksetzen, bevor top-up einen
                // frischen Titel nachlegt. Verhindert jede Stale-Situation.
                infinityPendingSongId = nil
                topUpInfinityIfNeeded()
            }
        }
    }
    @Published var queue: [Song] = []
    @Published var currentIndex: Int = 0
    @Published var playNextQueue: [Song] = []
    @Published var userQueue: [Song] = []
    var currentTime: Double = 0
    var duration: Double = 0
    let timePublisher = PassthroughSubject<(time: Double, duration: Double), Never>()
    @Published var isSeeking: Bool = false
    @Published var isShuffled: Bool = false {
        didSet { applyPlaybackModeToNowPlayingInfo() }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { applyPlaybackModeToNowPlayingInfo() }
    }
    @Published var isCarPlayActive: Bool = false {
        didSet {
            if isCarPlayActive && repeatMode == .one { repeatMode = .all }
        }
    }

    func cycleRepeatMode() {
        if isCarPlayActive {
            repeatMode = (repeatMode == .off) ? .all : .off
        } else {
            repeatMode = repeatMode.toggled
        }
    }

    @Published var actualStreamFormat: ActualStreamFormat?
    @Published var artworkReloadToken: UUID = UUID()

    #if os(macOS)
    /// Master-Volume des Desktop-Players (Lautstärkeregler in der PlayerBar).
    @Published var volume: Float = 1.0 {
        didSet { engine.volume = volume }
    }
    #endif

    private var formatProbeTask: Task<Void, Never>?
    private var fastSeekTimer: Timer?
    private var currentStreamURL: URL?
    private var streamTimeOffset: Double = 0
    private var networkResumeSong: Song?
    private var networkResumeTime: Double = 0

    var hasNextTrack: Bool {
        !playNextQueue.isEmpty ||
        currentIndex + 1 < queue.count ||
        !userQueue.isEmpty ||
        repeatMode == .all
    }

    var displayTitle: String {
        currentSong?.title ?? String(localized: "no_track")
    }

    private var truthAlbumQueue: [Song] = []
    private var truthPlayNextQueue: [Song] = []
    private var truthUserQueue: [Song] = []

    private let engine = PlayerEngine()
    private var engineSubscriptions = Set<AnyCancellable>()
    private var bufferingShowTask: Task<Void, Never>?
    #if os(tvOS)
    // tvOS: Watchdog der prüft, ob ein Resume wirklich losläuft (sonst Stream neu laden).
    private var resumeWatchdog: Task<Void, Never>?
    #endif
    private var lastArtworkCoverArt: String? = nil
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @AppStorage("streamPreCacheEnabled") private var streamPreCacheEnabled = false
    @AppStorage("streamPreCacheAheadCount") private var streamPreCacheAheadCount = 1
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true
    @AppStorage("replayGainEnabled") private var replayGainEnabled = false
    @AppStorage("replayGainMode") private var replayGainMode = "track"
    @AppStorage("infinityModeEnabled") private var infinityModeEnabled = false
    private var gaplessPreloadTriggered = false
    private var gaplessPreloadSong: Song? = nil
    private var gaplessPreloadURL: URL? = nil
    private var managedStreamCacheSongIds: Set<String> = []
    private var streamCacheWindowSongIds: [String] = []
    private var streamCacheWindowTask: Task<Void, Never>?
    private var isEngineLoaded = false
    private var playbackGeneration: Int = 0
    private var currentArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var lyricsAutoFetchTask: Task<Void, Never>?

    private var networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "shelv.network", qos: .utility)

    private var resumeTime: Double = 0
    private var lastReportedNowPlayingTime: Double = -1

    // Die alte Desktop-App persistierte unter shelv_mac_* (und einem anderen
    // Resume-Time-Suffix) — die Keys bleiben pro Plattform erhalten, damit
    // Bestands-Installationen ihre Queue/Position nicht verlieren.
    private enum StateKey {
        #if os(macOS)
        static let queue          = "shelv_mac_queue"
        static let index          = "shelv_mac_currentIndex"
        static let playNextQueue  = "shelv_mac_playNextQueue"
        static let userQueue      = "shelv_mac_userQueue"
        static let resumeTime     = "shelv_mac_currentTime"
        static let isShuffled     = "shelv_mac_isShuffled"
        static let repeatMode     = "shelv_mac_repeatMode"
        static let truthAlbum     = "shelv_mac_truthAlbum"
        static let truthPlayNext  = "shelv_mac_truthPlayNext"
        static let truthUserQueue = "shelv_mac_truthUserQueue"
        static let volume         = "shelv_mac_volume"
        #else
        static let queue          = "shelv_player_queue"
        static let index          = "shelv_player_currentIndex"
        static let playNextQueue  = "shelv_player_playNextQueue"
        static let userQueue      = "shelv_player_userQueue"
        static let resumeTime     = "shelv_player_resumeTime"
        static let isShuffled     = "shelv_player_isShuffled"
        static let repeatMode     = "shelv_player_repeatMode"
        static let truthAlbum     = "shelv_player_truthAlbum"
        static let truthPlayNext  = "shelv_player_truthPlayNext"
        static let truthUserQueue = "shelv_player_truthUserQueue"
        #endif
    }

    #if os(macOS)
    private var willTerminateObserver: NSObjectProtocol?
    #endif

    private init() {
        _ = NetworkStatus.shared
        #if os(iOS) || os(tvOS)
        setupAudioSession()
        #endif
        setupEngine()
        setupRemoteControls()
        #if os(iOS) || os(tvOS)
        setupInterruptionObserver()
        #endif
        setupNetworkMonitor()
        #if os(iOS) || os(tvOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        #elseif os(macOS)
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in self.saveState() }
        }
        #endif
        restoreState()
    }

    deinit {
        MainActor.assumeIsolated {
            NotificationCenter.default.removeObserver(self)
            #if os(macOS)
            if let obs = willTerminateObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            #endif
            networkMonitor.cancel()
        }
    }

    private func setupNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            // Synchroner Sync zu NetworkStatus.shared, damit ein anschliessender startPlayback
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
                    self.startPlayback(song: song, seekTo: t)
                }
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    @objc private func appDidEnterBackground() {
        saveState()
        // Vor einer möglichen Suspendierung sofort hochladen (Debounce überspringen).
        QueueSyncService.shared.flushUpload()
    }

    #if os(tvOS)
    /// tvOS-only: Queue-State wird in eine Datei persistiert statt in UserDefaults.
    /// CFPreferences hat auf tvOS ein hartes Größenlimit und bricht die App bei großen
    /// Shuffle-Queues per abort() ab. Caches genügt — wird der Eintrag bei einer
    /// System-Bereinigung gelöscht, entfällt nur die Wiederherstellung nach Neustart
    /// (kein Crash, keine Integritätsfrage; restoreState kehrt dann einfach früh zurück).
    private struct PersistedQueueState: Codable {
        var queue: [Song]
        var playNextQueue: [Song]
        var userQueue: [Song]
        var truthAlbum: [Song]
        var truthPlayNext: [Song]
        var truthUserQueue: [Song]
    }

    private var queueStateFileURL: URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("shelv_player_queue_state.json")
    }

    private func writeQueueStateFile() {
        guard let url = queueStateFileURL else { return }
        let state = PersistedQueueState(
            queue: queue,
            playNextQueue: playNextQueue,
            userQueue: userQueue,
            truthAlbum: truthAlbumQueue,
            truthPlayNext: truthPlayNextQueue,
            truthUserQueue: truthUserQueue
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func readQueueStateFile() -> PersistedQueueState? {
        guard let url = queueStateFileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedQueueState.self, from: data)
    }

    private func deleteQueueStateFile() {
        guard let url = queueStateFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
    #endif

    private func saveState() {
        let defaults = UserDefaults.standard
        // Skalare (klein) — auf allen Plattformen in UserDefaults.
        defaults.set(currentIndex, forKey: StateKey.index)
        defaults.set(currentTime, forKey: StateKey.resumeTime)
        defaults.set(isShuffled, forKey: StateKey.isShuffled)
        defaults.set(repeatMode.rawValue, forKey: StateKey.repeatMode)

        // Große Song-Arrays.
        #if os(tvOS)
        writeQueueStateFile()
        // Etwaige Alt-Daten aus UserDefaults tilgen (z.B. nach Update von einer Build,
        // die noch in die Defaults schrieb) — so bleibt der Prefs-Container garantiert klein.
        for key in [StateKey.queue, StateKey.playNextQueue, StateKey.userQueue,
                    StateKey.truthAlbum, StateKey.truthPlayNext, StateKey.truthUserQueue] {
            defaults.removeObject(forKey: key)
        }
        #else
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(queue) { defaults.set(data, forKey: StateKey.queue) }
        if let data = try? encoder.encode(playNextQueue) { defaults.set(data, forKey: StateKey.playNextQueue) }
        if let data = try? encoder.encode(userQueue) { defaults.set(data, forKey: StateKey.userQueue) }
        if let data = try? encoder.encode(truthAlbumQueue) { defaults.set(data, forKey: StateKey.truthAlbum) }
        if let data = try? encoder.encode(truthPlayNextQueue) { defaults.set(data, forKey: StateKey.truthPlayNext) }
        if let data = try? encoder.encode(truthUserQueue) { defaults.set(data, forKey: StateKey.truthUserQueue) }
        #endif

        #if os(macOS)
        defaults.set(Double(volume), forKey: StateKey.volume)
        #endif

        // Geräteübergreifender Queue-Sync (debounced; No-Op wenn Modus = off).
        // Position wird beim Upload live gelesen — saveState läuft nur an diskreten
        // Punkten (Mutationen, play/pause/stop, Songwechsel, Background), nicht periodisch.
        QueueSyncService.shared.scheduleUpload()
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
        defaults.removeObject(forKey: StateKey.truthAlbum)
        defaults.removeObject(forKey: StateKey.truthPlayNext)
        defaults.removeObject(forKey: StateKey.truthUserQueue)
        #if os(macOS)
        defaults.removeObject(forKey: StateKey.volume)
        #endif
        #if os(tvOS)
        deleteQueueStateFile()
        #endif
    }

    private func restoreState() {
        let defaults = UserDefaults.standard
        #if !os(tvOS)
        let decoder = JSONDecoder()
        #endif

        #if os(tvOS)
        // tvOS: große Arrays liegen in der Datei (siehe saveState).
        guard let fileState = readQueueStateFile(), !fileState.queue.isEmpty else { return }
        let restoredQueue = fileState.queue
        #else
        guard let queueData = defaults.data(forKey: StateKey.queue),
              let restoredQueue = try? decoder.decode([Song].self, from: queueData),
              !restoredQueue.isEmpty
        else { return }
        #endif

        queue = restoredQueue
        let idx = defaults.integer(forKey: StateKey.index)
        currentIndex = min(max(idx, 0), restoredQueue.count - 1)
        currentSong = restoredQueue[currentIndex]
        resumeTime = defaults.double(forKey: StateKey.resumeTime)
        currentTime = resumeTime
        if let d = currentSong?.duration { duration = Double(d) }

        #if os(tvOS)
        playNextQueue = fileState.playNextQueue
        userQueue = fileState.userQueue
        #else
        if let pnData = defaults.data(forKey: StateKey.playNextQueue),
           let pn = try? decoder.decode([Song].self, from: pnData) {
            playNextQueue = pn
        }
        if let uqData = defaults.data(forKey: StateKey.userQueue),
           let uq = try? decoder.decode([Song].self, from: uqData) {
            userQueue = uq
        }
        #endif

        isShuffled = defaults.bool(forKey: StateKey.isShuffled)
        if let raw = defaults.string(forKey: StateKey.repeatMode) {
            repeatMode = RepeatMode(rawValue: raw) ?? .off
        }

        #if os(tvOS)
        truthAlbumQueue = fileState.truthAlbum
        truthPlayNextQueue = fileState.truthPlayNext
        truthUserQueue = fileState.truthUserQueue
        #else
        if let data = defaults.data(forKey: StateKey.truthAlbum),
           let t = try? decoder.decode([Song].self, from: data) { truthAlbumQueue = t }
        if let data = defaults.data(forKey: StateKey.truthPlayNext),
           let t = try? decoder.decode([Song].self, from: data) { truthPlayNextQueue = t }
        if let data = defaults.data(forKey: StateKey.truthUserQueue),
           let t = try? decoder.decode([Song].self, from: data) { truthUserQueue = t }
        #endif

        #if os(macOS)
        let savedVolume = defaults.double(forKey: StateKey.volume)
        volume = savedVolume > 0 ? Float(savedVolume) : 1.0
        #endif

        if let song = currentSong { updateNowPlayingInfo(song: song) }
    }

    // MARK: - Queue-Sync (geräteübergreifend)

    /// Baut den aktuellen Wiedergabe-Zustand als Snapshot. `nil`, wenn nichts
    /// Sinnvolles vorliegt (komplett leere Queue).
    func makeSnapshot(serverId: String) -> QueueSnapshot? {
        guard !(queue.isEmpty && playNextQueue.isEmpty && userQueue.isEmpty) else { return nil }
        return QueueSnapshot(
            queue: queue,
            currentIndex: currentIndex,
            playNextQueue: playNextQueue,
            userQueue: userQueue,
            truthAlbumQueue: truthAlbumQueue,
            truthPlayNextQueue: truthPlayNextQueue,
            truthUserQueue: truthUserQueue,
            currentSongId: currentSong?.id,
            isShuffled: isShuffled,
            repeatMode: repeatMode.rawValue,
            serverId: serverId,
            changedAt: Date().timeIntervalSince1970
        )
    }

    /// Übernimmt eine fremde Queue (vom Banner ausgelöst). Lädt den aktuellen Song
    /// pausiert an der Position — kein Auto-Play, wie beim normalen Restore. Im
    /// Offline-Modus werden nicht heruntergeladene Songs übersprungen.
    func apply(_ snapshot: QueueSnapshot) {
        let serverId = snapshot.serverId
        let offline = OfflineModeService.shared.isOffline
        func avail(_ songs: [Song]) -> [Song] {
            guard offline else { return songs }
            return songs.filter { LocalDownloadIndex.shared.contains(songId: $0.id, serverId: serverId) }
        }

        var restoredQueue = avail(snapshot.queue)
        var restoredPlayNext = avail(snapshot.playNextQueue)
        var restoredUser = avail(snapshot.userQueue)
        guard !(restoredQueue.isEmpty && restoredPlayNext.isEmpty && restoredUser.isEmpty) else { return }

        // Ist der Hauptqueue nach der Offline-Filterung leer (aktueller Song nicht geladen),
        // aber Play-Next/User-Queue haben Songs → ersten verfügbaren als aktuellen nehmen,
        // sonst bliebe nichts abspielbar/aktuell.
        if restoredQueue.isEmpty {
            if !restoredPlayNext.isEmpty { restoredQueue = [restoredPlayNext.removeFirst()] }
            else if !restoredUser.isEmpty { restoredQueue = [restoredUser.removeFirst()] }
        }

        // currentIndex nach der Filterung anhand der currentSongId neu bestimmen.
        var idx = min(max(snapshot.currentIndex, 0), max(restoredQueue.count - 1, 0))
        if let cid = snapshot.currentSongId,
           let found = restoredQueue.firstIndex(where: { $0.id == cid }) {
            idx = found
        }

        queue = restoredQueue
        currentIndex = restoredQueue.isEmpty ? 0 : min(idx, restoredQueue.count - 1)
        playNextQueue = restoredPlayNext
        userQueue = restoredUser
        truthAlbumQueue = avail(snapshot.truthAlbumQueue)
        truthPlayNextQueue = avail(snapshot.truthPlayNextQueue)
        truthUserQueue = avail(snapshot.truthUserQueue)
        isShuffled = snapshot.isShuffled
        repeatMode = RepeatMode(rawValue: snapshot.repeatMode) ?? .off

        // Engine zurücksetzen: ggf. läuft noch der alte Song geladen in der Engine
        // (isEngineLoaded == true). Ohne Reset würde resume() den alten Item via
        // engine.resume() weiterspielen, obwohl currentSong bereits der neue ist.
        // isEngineLoaded zuerst auf false, damit der Time-Sink das Stop ignoriert.
        isEngineLoaded = false
        engine.stop()
        isPlaying = false
        isBuffering = false

        currentSong = restoredQueue.isEmpty ? nil : restoredQueue[currentIndex]
        // Bewusst keine Positions-Übernahme: der Song startet bei 0.
        resumeTime = 0
        currentTime = 0
        if let d = currentSong?.duration { duration = Double(d) }
        if let song = currentSong { updateNowPlayingInfo(song: song) }
        saveState()
    }

    #if os(iOS) || os(tvOS)
    private func setupAudioSession() {
        Task.detached(priority: .utility) {
            do {
                try Self.configureAudioSession()
            } catch {
                print("[AudioSession] initial activate failed: \(error)")
            }
        }
    }

    /// Kategorie setzen + Session aktivieren. Wird vor jeder Wiedergabe aufgerufen, weil tvOS
    /// die Session nach Pause/Stop/App-Wechsel deaktiviert und ein folgendes play() sonst stumm bleibt.
    func activateSession() {
        if Thread.isMainThread {
            Task { await activateSessionAsync() }
            return
        }

        do {
            try Self.configureAudioSession()
        } catch {
            print("[AudioSession] activate failed: \(error)")
        }
    }

    nonisolated private static func configureAudioSession() throws {
        #if os(tvOS)
        try AVAudioSession.sharedInstance().setCategory(.playback)
        #else
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.allowAirPlay, .allowBluetoothHFP]
        )
        #endif
        try AVAudioSession.sharedInstance().setActive(true)
    }

    @discardableResult
    private func activateSessionAsync(logMessage: String = "activate failed") async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                try Self.configureAudioSession()
                return true
            } catch {
                print("[AudioSession] \(logMessage): \(error)")
                return false
            }
        }.value
    }

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                if self.isPlaying { self.pause() }
            case .ended:
                if let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    if options.contains(.shouldResume), self.currentSong != nil {
                        // Audio-Session vor Resume reaktivieren — iOS deaktiviert sie bei Interruption
                        // (z.B. Anruf), und ohne explizites setActive(true) bleibt der Player lautlos
                        // obwohl er "spielt".
                        self.resume()
                    }
                }
            @unknown default:
                break
            }
        }
    }
    #endif

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

        cc.seekForwardCommand.isEnabled = true
        cc.seekForwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSeekCommandEvent else { return .commandFailed }
            Task { @MainActor in
                switch e.type {
                case .beginSeeking: self?.startFastSeeking(forward: true)
                case .endSeeking:   self?.stopFastSeeking()
                @unknown default:   break
                }
            }
            return .success
        }

        cc.seekBackwardCommand.isEnabled = true
        cc.seekBackwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSeekCommandEvent else { return .commandFailed }
            Task { @MainActor in
                switch e.type {
                case .beginSeeking: self?.startFastSeeking(forward: false)
                case .endSeeking:   self?.stopFastSeeking()
                @unknown default:   break
                }
            }
            return .success
        }

        // Apple's CPNowPlayingRepeatButton / -ShuffleButton rendern den Selected-State
        // nur konsistent, wenn die zugehörigen MPRemoteCommands aktiviert sind und ein
        // Target haben. Ohne das wirkt der Button beim Wechsel zwischen .all → .one
        // wie ein Aus-Sprung. Die Targets spiegeln Auto-/Siri-/Lock-Screen-Eingaben
        // zurück in unsere App-Logik.
        cc.changeRepeatModeCommand.isEnabled = true
        cc.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode = {
                switch e.repeatType {
                case .off:  return .off
                case .one:  return .one
                case .all:  return .all
                @unknown default: return .off
                }
            }()
            Task { @MainActor in self?.repeatMode = mode }
            return .success
        }

        cc.changeShuffleModeCommand.isEnabled = true
        cc.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let shouldShuffle = (e.shuffleType != .off)
            Task { @MainActor in
                guard let self else { return }
                if shouldShuffle != self.isShuffled { self.toggleShuffle() }
            }
            return .success
        }
    }

    func play(songs: [Song], startIndex: Int = 0) {
        isShuffled = false
        queue = songs
        currentIndex = startIndex
        playNextQueue = []
        userQueue = []
        truthAlbumQueue = songs
        truthPlayNextQueue = []
        truthUserQueue = []
        guard songs.indices.contains(startIndex) else { return }
        resumeTime = 0
        startPlayback(song: songs[startIndex], seekTo: 0)
        saveState()
    }

    func playSong(_ song: Song) {
        isShuffled = false
        queue = [song]
        currentIndex = 0
        playNextQueue = []
        userQueue = []
        truthAlbumQueue = [song]
        truthPlayNextQueue = []
        truthUserQueue = []
        resumeTime = 0
        startPlayback(song: song, seekTo: 0)
        saveState()
    }

    #if DEBUG
    /// Setzt ein festes Player-Standbild für Demo-Screenshots: ein bestimmter Song bei fester
    /// Position, pausiert, ohne echte Wiedergabe. Die Engine wird bewusst nicht geladen
    /// (`isEngineLoaded` bleibt `false`), daher überschreibt der Time-Observer `currentTime`
    /// nicht. `PlayerView` liest `currentTime`/`duration` in `onAppear` direkt.
    func loadDemoStandby() {
        engine.stop()
        isEngineLoaded = false
        isShuffled = false
        queue = DemoContent.playerQueue
        currentIndex = DemoContent.playerCurrentIndex
        playNextQueue = []
        userQueue = []
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

    private func probeStreamFormat(for song: Song, url: URL) {
        formatProbeTask?.cancel()
        let songDuration = Double(song.duration ?? 0)

        // 1) Sofortiger, provisorischer Wert — Bitrate exakt, Codec ggf. noch aus
        //    Dateiendung/MIME geraten (kann ALAC nicht von AAC unterscheiden).
        var initialBitrate: Int? = nil
        if url.isFileURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 0, songDuration > 1 { initialBitrate = Int(Double(size) * 8 / songDuration / 1000) }
            let ext = url.pathExtension.uppercased()
            actualStreamFormat = ActualStreamFormat(codecLabel: ext.isEmpty ? "?" : ext, bitrateKbps: initialBitrate)
        } else {
            actualStreamFormat = nil
        }

        formatProbeTask = Task { [weak self] in
            guard let self else { return }
            var bitrate = initialBitrate

            // 2) Remote: HEAD für exakte Bitrate (Content-Length) + provisorischer Codec.
            if !url.isFileURL {
                var req = URLRequest(url: url)
                req.httpMethod = "HEAD"
                req.timeoutInterval = 8
                if let (_, response) = try? await URLSession.shared.data(for: req),
                   let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    let codec = ActualStreamFormat.codecLabel(forMime: http.mimeType)
                    let length = http.expectedContentLength
                    if length > 0, songDuration > 1 { bitrate = Int(Double(length) * 8 / songDuration / 1000) }
                    if Task.isCancelled { return }
                    await MainActor.run { self.actualStreamFormat = ActualStreamFormat(codecLabel: codec, bitrateKbps: bitrate) }
                }
            }

            // 3) Echten Codec aus dem geladenen Player-Track nachziehen (ALAC vs. AAC).
            //    engine.play() kann nach diesem Probe kommen + der Track lädt async,
            //    daher bis zu ~4s pollen. Bitrate bleibt die bewährte Rechnung;
            //    der Player-Schätzwert dient nur als Fallback.
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if let real = await self.engine.currentAudioFormat(matching: url) {
                    if Task.isCancelled { return }
                    let finalBitrate = bitrate ?? real.bitrateKbps
                    await MainActor.run {
                        self.actualStreamFormat = ActualStreamFormat(codecLabel: real.codec, bitrateKbps: finalBitrate)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func resolveURL(for song: Song) -> URL? {
        let serverId = SubsonicAPIService.shared.activeServer?.stableId ?? ""
        if !serverId.isEmpty,
           let local = LocalDownloadIndex.shared.url(songId: song.id, serverId: serverId) {
            return local
        }
        guard !OfflineModeService.shared.isOffline else { return nil }
        return SubsonicAPIService.shared.streamURL(for: song.id)
    }

    private func scheduleLyricsAutoFetch(for song: Song?) {
        lyricsAutoFetchTask?.cancel()
        guard autoFetchLyrics,
              !UserDefaults.standard.bool(forKey: "offlineModeEnabled"),
              let song,
              let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString
        else { return }

        lyricsAutoFetchTask = Task(priority: .utility) { [song, serverId] in
            await LyricsService.shared.setup()
            guard !Task.isCancelled else { return }
            _ = await LyricsService.shared.fetchAndSave(song: song, serverId: serverId)
        }
    }

    private func isTranscodedRemote(_ url: URL) -> Bool {
        guard !url.isFileURL else { return false }
        return url.queryParam("format").map { $0 != "raw" } ?? false
    }

    private struct StreamCacheJob: Sendable {
        let songId: String
        let title: String
        let url: URL
        let codec: String
        let bitrate: Int
    }

    private var selectedStreamPreCacheAheadCount: Int {
        min(max(streamPreCacheAheadCount, 1), 5)
    }

    private var backgroundStreamPreCacheLimit: Int {
        if streamPreCacheEnabled { return selectedStreamPreCacheAheadCount }
        return TranscodingPolicy.currentStreamFormat() == nil ? 0 : 1
    }

    private func isDownloadedLocally(_ song: Song) -> Bool {
        let serverId = SubsonicAPIService.shared.activeServer?.stableId ?? ""
        guard !serverId.isEmpty else { return false }
        return LocalDownloadIndex.shared.url(songId: song.id, serverId: serverId) != nil
    }

    private func upcomingSongs(limit: Int) -> [Song] {
        guard limit > 0 else { return [] }
        var candidates = playNextQueue
        let start = currentIndex + 1
        if start < queue.count {
            candidates.append(contentsOf: queue[start...])
        }
        candidates.append(contentsOf: userQueue)

        var seen: Set<String> = []
        let currentId = currentSong?.id
        var result: [Song] = []
        for song in candidates where song.id != currentId {
            guard seen.insert(song.id).inserted else { continue }
            result.append(song)
            if result.count == limit { break }
        }
        return result
    }

    private func streamCacheJob(for song: Song) -> StreamCacheJob? {
        guard !OfflineModeService.shared.isOffline,
              !isDownloadedLocally(song),
              let url = SubsonicAPIService.shared.streamURL(for: song.id),
              !url.isFileURL
        else { return nil }

        if isTranscodedRemote(url), let fmt = TranscodingPolicy.currentStreamFormat() {
            return StreamCacheJob(
                songId: song.id,
                title: song.title,
                url: url,
                codec: fmt.codec.rawValue,
                bitrate: fmt.bitrate
            )
        }

        guard streamPreCacheEnabled else { return nil }
        return StreamCacheJob(
            songId: song.id,
            title: song.title,
            url: url,
            codec: song.suffix?.lowercased() ?? "audio",
            bitrate: 0
        )
    }

    private func desiredStreamCacheJobs() -> [StreamCacheJob] {
        upcomingSongs(limit: backgroundStreamPreCacheLimit).compactMap { streamCacheJob(for: $0) }
    }

    private func currentStreamCacheKeepIds() -> Set<String> {
        guard let currentSong else { return [] }
        return Set(desiredStreamCacheJobs().map(\.songId)).union([currentSong.id])
    }

    private func trimManagedStreamCaches(keeping keepIds: Set<String>) {
        streamCacheWindowTask?.cancel()
        streamCacheWindowTask = nil
        streamCacheWindowSongIds = []
        let staleIds = managedStreamCacheSongIds.subtracting(keepIds)
        managedStreamCacheSongIds.formIntersection(keepIds)
        guard !staleIds.isEmpty else { return }
        Task {
            for songId in staleIds {
                await StreamCacheService.shared.cancel(songId: songId)
            }
        }
    }

    private func cancelAllManagedStreamCaches() {
        streamCacheWindowTask?.cancel()
        streamCacheWindowTask = nil
        streamCacheWindowSongIds = []
        let staleIds = managedStreamCacheSongIds
        managedStreamCacheSongIds.removeAll()
        guard !staleIds.isEmpty else { return }
        Task {
            for songId in staleIds {
                await StreamCacheService.shared.cancel(songId: songId)
            }
        }
    }

    func refreshStreamPreCacheWindow() {
        guard currentSong != nil else {
            cancelAllManagedStreamCaches()
            return
        }
        trimManagedStreamCaches(keeping: currentStreamCacheKeepIds())
        if currentTime >= 5 {
            refreshStreamCacheWindow(force: true)
        }
    }

    private func refreshStreamCacheWindow(force: Bool = false) {
        guard let currentSong else {
            cancelAllManagedStreamCaches()
            return
        }
        let jobs = desiredStreamCacheJobs()
        let keepIds = Set(jobs.map(\.songId)).union([currentSong.id])
        let signature = [currentSong.id] + jobs.map(\.songId)
        guard force || signature != streamCacheWindowSongIds else { return }

        streamCacheWindowSongIds = signature
        streamCacheWindowTask?.cancel()
        streamCacheWindowTask = Task { @MainActor [weak self, jobs, keepIds] in
            guard let self else { return }
            let staleIds = self.managedStreamCacheSongIds.subtracting(keepIds)
            self.managedStreamCacheSongIds.formIntersection(keepIds)
            for songId in staleIds {
                guard !Task.isCancelled else { return }
                await StreamCacheService.shared.cancel(songId: songId)
            }
            for job in jobs {
                guard !Task.isCancelled else { return }
                self.managedStreamCacheSongIds.insert(job.songId)
                await StreamCacheService.shared.prefetchAndWait(
                    songId: job.songId,
                    url: job.url,
                    codec: job.codec,
                    bitrate: job.bitrate,
                    songTitle: job.title
                )
            }
        }
    }

    private func startPlayback(song: Song, seekTo: Double = 0) {
        stopFastSeeking()
        playbackGeneration += 1
        let gen = playbackGeneration
        #if os(tvOS)
        resumeWatchdog?.cancel()
        #endif
        Task { @MainActor [weak self] in
            guard let self else { return }
            #if os(iOS) || os(tvOS)
            await self.activateSessionAsync()
            guard self.playbackGeneration == gen else { return }
            #endif
            self.networkResumeSong = nil
            self.isEngineLoaded = false
            await NetworkStatus.shared.waitUntilReady()

            guard self.playbackGeneration == gen else { return }

            guard let url = self.resolveURL(for: song) else {
                if OfflineModeService.shared.isOffline {
                    #if os(iOS)
                    NotificationCenter.default.post(name: .offlinePlaybackBlocked, object: nil)
                    #elseif os(macOS)
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "not_available_offline"))
                    #endif
                    // tvOS: kein Offline-Modus (keine Downloads) — Pfad unerreichbar.
                }
                return
            }

            self.currentStreamURL = url
            self.streamTimeOffset = 0
            self.gaplessPreloadTriggered = false
            self.gaplessPreloadSong = nil
            self.gaplessPreloadURL = nil
            self.formatProbeTask?.cancel()
            self.actualStreamFormat = nil
            self.currentSong = song
            self.trimManagedStreamCaches(keeping: self.currentStreamCacheKeepIds())
            self.scheduleLyricsAutoFetch(for: song)
            self.applyReplayGain(for: song)
            self.isBuffering = false
            self.isBuffering = true
            self.isSeeking = false
            self.currentTime = 0
            if let d = song.duration { self.duration = Double(d) }
            self.timePublisher.send((time: 0, duration: self.duration))

            self.isPlaying = true
            if song.coverArt != self.lastArtworkCoverArt {
                self.artworkReloadToken = UUID()
                self.lastArtworkCoverArt = song.coverArt
            }
            MPNowPlayingInfoCenter.default().playbackState = .playing
            self.updateNowPlayingInfo(song: song)
            #if os(macOS)
            // Navidrome-„spielt gerade"-Anzeige (kein Play-Count): bisheriges Desktop-Verhalten.
            Task { try? await SubsonicAPIService.shared.scrobble(songId: song.id, submission: false) }
            #endif

            // Transcodierter Remote-Stream → erst cachen, dann lokal abspielen
            if self.isTranscodedRemote(url), let fmt = TranscodingPolicy.currentStreamFormat() {
                self.engine.stop()
                let songId = song.id
                // Erwartetes Format sofort setzen; der Cache aktualisiert es nach der Server-Antwort.
                self.actualStreamFormat = ActualStreamFormat(
                    codecLabel: fmt.codec.rawValue.uppercased(),
                    bitrateKbps: fmt.bitrate
                )
                await StreamCacheService.shared.prefetch(
                    songId: songId,
                    url: url,
                    codec: fmt.codec.rawValue,
                    bitrate: fmt.bitrate,
                    songTitle: song.title
                )
                self.managedStreamCacheSongIds.insert(songId)
                #if os(iOS)
                // Background-Task damit iOS den Download nicht einfriert wenn Handy gesperrt wird
                // bevor der erste Song je gespielt hat (kein aktiver Audio-Kontext vorhanden)
                let bgTask = UIApplication.shared.beginBackgroundTask(withName: "shelv.streamload")
                defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }
                #endif
                // Polling bis Datei da ist (alle 200ms, max 60s)
                // repeat…while: erst schlafen, dann prüfen — Download hat gerade erst gestartet
                let deadline = Date().addingTimeInterval(60)
                repeat {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard self.playbackGeneration == gen else { return }
                    if let local = await StreamCacheService.shared.localURL(for: songId) {
                        let asset = AVURLAsset(url: local, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                        let cmTime = try? await asset.load(.duration)
                        guard self.playbackGeneration == gen else { return }
                        let precise = cmTime.flatMap { $0.isValid && !$0.isIndefinite ? CMTimeGetSeconds($0) : nil }
                        let resolvedDuration = (precise ?? 0) > 0 ? precise! : Double(song.duration ?? 0)
                        self.currentStreamURL = local
                        let cachedFormat = await StreamCacheService.shared.cachedFormat(for: songId)
                        guard self.playbackGeneration == gen else { return }
                        if let cachedFormat {
                            self.actualStreamFormat = cachedFormat
                        }
                        self.probeStreamFormat(for: song, url: local)
                        self.engine.play(url: local)
                        if !self.isPlaying { self.engine.pause() }
                        self.engine.trustedDuration = resolvedDuration
                        self.duration = resolvedDuration
                        if seekTo > 0 { self.engine.seek(to: seekTo) }
                        self.isEngineLoaded = true
                        break
                    }
                } while Date() < deadline
                // Timeout-Fallback: Raw-Stream versuchen
                if self.playbackGeneration == gen, !self.isEngineLoaded,
                   let rawURL = SubsonicAPIService.shared.rawStreamURL(for: songId) {
                    self.currentStreamURL = rawURL
                    self.probeStreamFormat(for: song, url: rawURL)
                    self.engine.play(url: rawURL)
                    if !self.isPlaying { self.engine.pause() }
                    self.engine.trustedDuration = Double(song.duration ?? 0)
                    if seekTo > 0 { self.engine.seek(to: seekTo) }
                    self.isEngineLoaded = true
                }
            } else if !url.isFileURL, self.streamPreCacheEnabled {
                // Original-Remote-Stream mit Pre-Cache → erst vollständig laden, dann lokal abspielen
                self.engine.stop()
                let songId = song.id
                let suffix = song.suffix?.lowercased() ?? "audio"
                await StreamCacheService.shared.prefetch(
                    songId: songId,
                    url: url,
                    codec: suffix,
                    bitrate: 0,
                    songTitle: song.title
                )
                self.managedStreamCacheSongIds.insert(songId)
                let deadline = Date().addingTimeInterval(60)
                repeat {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard self.playbackGeneration == gen else { return }
                    if let local = await StreamCacheService.shared.localURL(for: songId) {
                        let asset = AVURLAsset(url: local, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                        let cmTime = try? await asset.load(.duration)
                        guard self.playbackGeneration == gen else { return }
                        let precise = cmTime.flatMap { $0.isValid && !$0.isIndefinite ? CMTimeGetSeconds($0) : nil }
                        let resolvedDuration = (precise ?? 0) > 0 ? precise! : Double(song.duration ?? 0)
                        self.currentStreamURL = local
                        self.probeStreamFormat(for: song, url: local)
                        self.engine.play(url: local)
                        if !self.isPlaying { self.engine.pause() }
                        self.engine.trustedDuration = resolvedDuration
                        self.duration = resolvedDuration
                        if seekTo > 0 { self.engine.seek(to: seekTo) }
                        self.isEngineLoaded = true
                        break
                    }
                } while Date() < deadline
                // Timeout-Fallback: direkt streamen
                if self.playbackGeneration == gen, !self.isEngineLoaded {
                    self.probeStreamFormat(for: song, url: url)
                    self.engine.play(url: url)
                    if !self.isPlaying { self.engine.pause() }
                    self.engine.trustedDuration = Double(song.duration ?? 0)
                    if seekTo > 0 { self.engine.seek(to: seekTo) }
                    self.isEngineLoaded = true
                }
            } else {
                // Raw-Stream oder lokale Datei → wie bisher
                self.probeStreamFormat(for: song, url: url)
                self.engine.play(url: url)
                self.engine.trustedDuration = Double(song.duration ?? 0)
                if seekTo > 0 { self.engine.seek(to: seekTo) }
                self.isEngineLoaded = true
            }
        }
    }

    private func clearPlaybackState() {
        cancelAllManagedStreamCaches()
        teardownPlayer()
        #if os(tvOS)
        resumeWatchdog?.cancel()
        #endif
        isPlaying = false
        isBuffering = false
        currentSong = nil
        currentTime = 0
        duration = 0
        currentStreamURL = nil
        streamTimeOffset = 0
        networkResumeSong = nil
        networkResumeTime = 0
        lyricsAutoFetchTask?.cancel()
        formatProbeTask?.cancel()
        actualStreamFormat = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func teardownPlayer() {
        artworkTask?.cancel()
        artworkTask = nil
        engine.stop()
        isEngineLoaded = false
    }

    func pause() {
        networkResumeSong = nil
        #if os(tvOS)
        resumeWatchdog?.cancel()
        #endif
        MPNowPlayingInfoCenter.default().playbackState = .paused
        engine.pause()
        isPlaying = false
        isBuffering = false
        updateNowPlayingPlaybackRate(0)
        saveState()
    }

    func resume() {
        guard let song = currentSong else { return }
        if !isEngineLoaded {
            let seek = resumeTime
            resumeTime = 0
            startPlayback(song: song, seekTo: seek)
        } else {
            #if os(iOS) || os(tvOS)
            let gen = playbackGeneration
            let expectedSongId = song.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.activateSessionAsync(logMessage: "Reaktivierung vor Resume fehlgeschlagen")
                guard self.playbackGeneration == gen,
                      self.isEngineLoaded,
                      self.currentSong?.id == expectedSongId
                else { return }
                self.resumeLoadedPlayback(song: song)
            }
            #else
            resumeLoadedPlayback(song: song)
            #endif
        }
    }

    private func resumeLoadedPlayback(song: Song) {
        engine.resume()
        isPlaying = true
        updateNowPlayingPlaybackRate(1)
        MPNowPlayingInfoCenter.default().playbackState = .playing

        #if os(tvOS)
        // tvOS verwirft den Puffer eines pausierten HTTP-Streams; play() am alten Item läuft
        // dann nicht mehr los. Watchdog: schreitet die Zeit nach ~1,2 s nicht fort, den Stream
        // an der aktuellen Position neu laden — das funktioniert zuverlässig (wie ein Neustart).
        let resumePosition = currentTime
        let expectedId = song.id
        resumeWatchdog?.cancel()
        resumeWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled, self.isPlaying,
                  self.currentSong?.id == expectedId,
                  self.currentTime <= resumePosition + 0.3 else { return }
            self.startPlayback(song: song, seekTo: resumePosition)
        }
        #endif
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func stop() {
        stopFastSeeking()
        clearPlaybackState()
        queue = []
        currentIndex = 0
        playNextQueue = []
        userQueue = []
        resumeTime = 0
        truthAlbumQueue = []
        truthPlayNextQueue = []
        truthUserQueue = []
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
        truthAlbumQueue = songs
        truthPlayNextQueue = []
        truthUserQueue = []

        resumeTime = 0
        startPlayback(song: shuffled[0])
        saveState()
    }

    func toggleShuffle() {
        let wasShuffled = isShuffled
        isShuffled = !wasShuffled
        if wasShuffled {
            let remainingAlbum: Set<String> = currentIndex + 1 < queue.count
                ? Set(queue[(currentIndex + 1)...].map { $0.id }) : []
            let remainingPN = Set(playNextQueue.map { $0.id })
            let remainingUQ = Set(userQueue.map { $0.id })
            let allRemaining = remainingAlbum.union(remainingPN).union(remainingUQ)
            let currentId = currentSong?.id

            let restoredAlbum = truthAlbumQueue.filter {
                $0.id != currentId && allRemaining.contains($0.id)
            }
            if let cur = currentSong {
                queue = [cur] + restoredAlbum
            } else {
                queue = restoredAlbum
            }
            currentIndex = 0
            playNextQueue = truthPlayNextQueue.filter {
                $0.id != currentId && allRemaining.contains($0.id)
            }
            userQueue = truthUserQueue.filter {
                $0.id != currentId && allRemaining.contains($0.id)
            }
        } else {
            let upcoming = (currentIndex + 1 < queue.count ? Array(queue[(currentIndex + 1)...]) : [])
                + userQueue
            let shuffled = upcoming.shuffled()

            queue.replaceSubrange((currentIndex + 1)..., with: shuffled)
            userQueue = []
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
            if let i = truthPlayNextQueue.firstIndex(where: { $0.id == song.id }) {
                truthPlayNextQueue.remove(at: i)
            }
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
            } else if repeatMode == .all && !(truthAlbumQueue.isEmpty && truthUserQueue.isEmpty) {
                let fullTruth = truthAlbumQueue + truthUserQueue
                truthAlbumQueue = fullTruth
                truthUserQueue = []
                truthPlayNextQueue = []
                queue = isShuffled ? fullTruth.shuffled() : fullTruth
                playNextQueue = []
                userQueue = []
                currentIndex = 0
                if queue.isEmpty { clearPlaybackState() } else { startPlayback(song: queue[0]) }
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
        lastReportedNowPlayingTime = -1
        updateNowPlayingTime(seconds)
        // loadedTimeRanges fragen: ist die Zielposition im Buffer? Wenn nicht UND der Player
        // gerade spielt → aktiv pausieren und auf isPlaybackLikelyToKeepUp warten. Wenn der
        // User schon pausiert hat, NICHT pause-and-resume, sonst springt der Player gegen
        // seinen Wunsch wieder an.
        let buffered = engine.isPositionBuffered(seconds)
        let shouldPauseAndWait = !buffered && self.isPlaying
        if shouldPauseAndWait { isBuffering = true }
        engine.seek(to: seconds, pauseUntilBuffered: shouldPauseAndWait) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isSeeking = false }
        }
    }

    private func startFastSeeking(forward: Bool) {
        fastSeekTimer?.invalidate()
        let step: Double = forward ? 3.0 : -3.0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentSong != nil else { return }
                let proposed = self.currentTime + step
                // Obergrenze nur clampen, wenn die Dauer bekannt ist — sonst würde ein noch
                // nicht geladenes Item (duration == 0) den Sprung auf 0 erzwingen.
                let newTime: Double = self.duration > 1
                    ? max(0, min(proposed, self.duration - 0.5))
                    : max(0, proposed)
                // isSeeking blockt den engine.$currentTime-Sink, damit der periodische
                // Observer unsere manuelle Position nicht überschreibt.
                self.isSeeking = true
                self.currentTime = newTime
                self.lastReportedNowPlayingTime = -1
                self.updateNowPlayingTime(newTime)
                // currentTime ist nicht @Published — die UI (In-App-Scrubber, Lock-Screen)
                // hängt am timePublisher, daher hier explizit pushen.
                self.timePublisher.send((time: newTime, duration: self.duration))
                self.engine.seek(to: newTime, pauseUntilBuffered: false)
            }
        }
        // .common-Modus: feuert auch während UI-Tracking; RunLoop.main statt .current
        // macht das Scheduling unabhängig vom aufrufenden Runloop.
        RunLoop.main.add(timer, forMode: .common)
        fastSeekTimer = timer
        timer.fire()
    }

    private func stopFastSeeking() {
        fastSeekTimer?.invalidate()
        fastSeekTimer = nil
        isSeeking = false
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
        if let i = truthPlayNextQueue.firstIndex(where: { $0.id == song.id }) {
            truthPlayNextQueue.remove(at: i)
        }
        startPlayback(song: song)
        saveState()
    }

    func jumpToQueueTrack(at queueIndex: Int) {
        guard queue.indices.contains(queueIndex), queueIndex > currentIndex else { return }
        let song = queue.remove(at: queueIndex)
        startPlayback(song: song)
        saveState()
    }

    func jumpToUserQueue(at index: Int) {
        guard userQueue.indices.contains(index) else { return }
        let song = userQueue.remove(at: index)
        startPlayback(song: song)
        saveState()
    }

    func addPlayNext(_ song: Song) {
        removePendingInfinitySong()
        truthPlayNextQueue.append(song)
        playNextQueue.append(song)
        saveState()
    }

    func addPlayNext(_ songs: [Song]) {
        removePendingInfinitySong()
        truthPlayNextQueue.append(contentsOf: songs)
        playNextQueue.append(contentsOf: songs)
        saveState()
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

    func addToQueue(_ song: Song) {
        removePendingInfinitySong()
        truthUserQueue.append(song)
        if isShuffled {
            insertRandomlyInShuffledQueue(song)
        } else {
            userQueue.append(song)
        }
        saveState()
    }

    // MARK: - Endlos-Modus (Radio)

    private var infinityPool: [Song] = []
    private var infinityTopUpTask: Task<Void, Never>?
    /// ID des einen Titels, den der Endlos-Modus vorausgelegt hat. Sobald der User selbst etwas
    /// einreiht (Add to Queue / Play Next), wird genau dieser Song wieder entfernt — der bewusst
    /// gewählte Inhalt kommt direkt dran, nicht hinter dem Radio-Auffüller.
    private var infinityPendingSongId: String?

    /// Hält bei aktivem Endlos-Modus immer genau einen Zufallstitel bereit (Precache-freundlich).
    /// - `startIfIdle`: nur `true` beim manuellen Einschalten des Toggles — dann startet bei
    ///   nichts-läuft sofort ein Zufallstitel. Beim Songwechsel `false`, damit nach einem Stop
    ///   die Wiedergabe nicht ungewollt wieder anspringt.
    func topUpInfinityIfNeeded(startIfIdle: Bool = false) {
        guard infinityModeEnabled, infinityTopUpTask == nil else { return }
        // Bei aktivem Repeat NICHT nachfüllen: peekNextSong() liefert am Queue-Ende bewusst nil
        // (für den Wrap/Replay). Ohne diesen Guard würde stattdessen ein Zufallstitel angehängt.
        guard repeatMode == .off else { return }
        // Schon etwas upcoming? Nichts tun.
        if currentSong != nil, peekNextSong() != nil { return }
        // Nichts am Laufen und kein expliziter Start → nichts tun (kein Wiederbeleben nach Stop).
        if currentSong == nil, !startIfIdle { return }
        infinityTopUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.infinityTopUpTask = nil }
            guard let song = await self.nextInfinitySong() else { return }
            guard self.infinityModeEnabled else { return }
            if self.currentSong == nil {
                if startIfIdle { self.play(songs: [song]) }
            } else if self.peekNextSong() == nil {
                self.appendInfinitySong(song)
            }
        }
    }

    /// Legt den vom Endlos-Modus gelieferten Titel ans Queue-Ende und merkt ihn als "pending"
    /// vor. Bewusst nicht über das öffentliche `addToQueue`, damit der eigene Auffüller nicht
    /// sofort wieder durch `removePendingInfinitySong()` entfernt würde.
    private func appendInfinitySong(_ song: Song) {
        truthUserQueue.append(song)
        if isShuffled {
            insertRandomlyInShuffledQueue(song)
        } else {
            userQueue.append(song)
        }
        infinityPendingSongId = song.id
        saveState()
    }

    /// Entfernt den einen vorgemerkten Infinity-Song aus der Queue (egal ob in `userQueue` oder
    /// — im Shuffle — im `queue`-Tail). Wird vor jeder expliziten Nutzer-Einreihung aufgerufen.
    private func removePendingInfinitySong() {
        guard let id = infinityPendingSongId else { return }
        infinityPendingSongId = nil
        if let i = userQueue.firstIndex(where: { $0.id == id }) {
            userQueue.remove(at: i)
        } else if let i = queue.firstIndex(where: { $0.id == id }), i > currentIndex {
            queue.remove(at: i)
        }
        if let i = truthUserQueue.firstIndex(where: { $0.id == id }) {
            truthUserQueue.remove(at: i)
        }
    }

    @MainActor
    private func nextInfinitySong() async -> Song? {
        if infinityPool.isEmpty { await refillInfinityPool() }
        while !infinityPool.isEmpty {
            let song = infinityPool.removeFirst()
            if song.id != currentSong?.id { return song }
        }
        return nil
    }

    @MainActor
    private func refillInfinityPool() async {
        // Online: bis zu 3 Versuche (mit kleinem Backoff), bevor auf Downloads ausgewichen wird.
        // Offline: gar nicht erst beim Server versuchen — direkt Downloads (dort ist garantiert was).
        if !OfflineModeService.shared.isOffline {
            for attempt in 0..<3 {
                if let songs = try? await SubsonicAPIService.shared.getRandomSongs(size: 25), !songs.isEmpty {
                    infinityPool = songs.shuffled()
                    return
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(500 * (attempt + 1))) }
            }
        }
        // Offline oder Online-Fehler → Fallback auf Downloads.
        let serverId = SubsonicAPIService.shared.activeServer?.stableId ?? ""
        guard !serverId.isEmpty else { return }
        let records = await DownloadDatabase.shared.allRecords(serverId: serverId)
        infinityPool = records.map { rec in
            Song(
                id: rec.songId, title: rec.title, artist: rec.artistName, artistId: rec.artistId,
                album: rec.albumTitle, albumId: rec.albumId, track: rec.track, discNumber: rec.disc,
                duration: rec.duration, coverArt: rec.coverArtId ?? rec.albumCoverArtId,
                year: nil, genre: nil, playCount: nil, starred: nil, contentType: nil,
                suffix: rec.fileExtension, bitRate: nil, replayGain: nil
            )
        }.shuffled()
    }

    func addToQueue(_ songs: [Song]) {
        removePendingInfinitySong()
        truthUserQueue.append(contentsOf: songs)
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
        let songId = userQueue[index].id
        userQueue.remove(at: index)
        if let i = truthUserQueue.firstIndex(where: { $0.id == songId }) {
            truthUserQueue.remove(at: i)
        }
        saveState()
    }

    func clearUserQueue() {
        userQueue = []
        truthUserQueue = []
        saveState()
    }

    func removeFromPlayQueue(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        let songId = queue[index].id
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        if let i = truthAlbumQueue.firstIndex(where: { $0.id == songId }) {
            truthAlbumQueue.remove(at: i)
        } else if let i = truthUserQueue.firstIndex(where: { $0.id == songId }) {
            truthUserQueue.remove(at: i)
        }
        saveState()
    }

    func clearUpcomingPlayQueue() {
        playNextQueue = []
        let start = currentIndex + 1
        if start < queue.count {
            queue.removeSubrange(start...)
        }
        truthPlayNextQueue = []
        truthUserQueue = []
        let currentId = currentSong?.id
        if let cur = currentId {
            truthAlbumQueue = truthAlbumQueue.filter { $0.id == cur }
        } else {
            truthAlbumQueue = []
        }
        saveState()
    }

    func moveInPlayNextQueue(from source: IndexSet, to destination: Int) {
        playNextQueue.move(fromOffsets: source, toOffset: destination)
        truthPlayNextQueue = playNextQueue
        saveState()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let oldAlbumTruth = truthAlbumQueue
        let oldUserTruth = truthUserQueue
        let offset = currentIndex + 1
        let absoluteSource = IndexSet(source.map { $0 + offset })
        let absoluteDestination = destination + offset
        queue.move(fromOffsets: absoluteSource, toOffset: absoluteDestination)
        if !isShuffled {
            truthAlbumQueue = Self.rebuildTruthPreservingTapped(
                oldTruth: oldAlbumTruth, newVisible: queue
            )
            let visibleIds = Set(queue.map { $0.id })
            truthUserQueue = oldUserTruth.filter { !visibleIds.contains($0.id) }
        }
        saveState()
    }

    func moveInUserQueue(from source: IndexSet, to destination: Int) {
        let oldTruth = truthUserQueue
        userQueue.move(fromOffsets: source, toOffset: destination)
        truthUserQueue = Self.rebuildTruthPreservingTapped(
            oldTruth: oldTruth, newVisible: userQueue
        )
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

    private func setupEngine() {
        engine.onTrackFinished = { [weak self] in
            guard let self else { return }
            if self.gaplessPreloadTriggered, let song = self.gaplessPreloadSong, self.gaplessPreloadURL != nil {
                let url = self.gaplessPreloadURL
                self.gaplessPreloadTriggered = false
                self.gaplessPreloadSong = nil
                self.gaplessPreloadURL = nil

                // Queue darf zwischen Preload und tatsächlichem Songende mutiert worden
                // sein. Nur swappen, wenn der vorgepufferte Song noch der nächste ist —
                // sonst regulär next() laufen lassen, das räumt den preloaded Item ab.
                guard self.peekNextSong()?.id == song.id else {
                    self.next(triggeredByUser: false)
                    return
                }

                self.advanceQueueState()
                self.currentSong = song
                self.trimManagedStreamCaches(keeping: self.currentStreamCacheKeepIds())
                self.scheduleLyricsAutoFetch(for: song)
                self.applyReplayGain(for: song)
                self.currentTime = 0
                self.isSeeking = false
                self.isEngineLoaded = true
                self.isBuffering = false
                self.streamTimeOffset = 0
                self.currentStreamURL = url
                if let d = song.duration { self.duration = Double(d) }
                self.engine.trustedDuration = Double(song.duration ?? 0)
                self.updateNowPlayingInfo(song: song)
                MPNowPlayingInfoCenter.default().playbackState = .playing
                if let url {
                    self.probeStreamFormat(for: song, url: url)
                }
                #if os(macOS)
                Task { try? await SubsonicAPIService.shared.scrobble(songId: song.id, submission: false) }
                #endif
                self.saveState()
            } else {
                self.gaplessPreloadTriggered = false
                self.gaplessPreloadSong = nil
                self.gaplessPreloadURL = nil
                self.next(triggeredByUser: false)
            }
        }

        engine.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self, self.isEngineLoaded, !self.isSeeking else { return }
                let adjusted = time + self.streamTimeOffset
                self.currentTime = adjusted
                self.timePublisher.send((time: adjusted, duration: self.duration))
                self.updateNowPlayingTime(adjusted)
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

    private func peekNextSong() -> Song? {
        if !playNextQueue.isEmpty { return playNextQueue[0] }
        let nextIndex = currentIndex + 1
        if nextIndex < queue.count { return queue[nextIndex] }
        if !userQueue.isEmpty { return userQueue[0] }
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

    private func checkGaplessTrigger(currentTime: Double) {
        guard duration > 11 else { return }
        guard !(repeatMode == .one && playNextQueue.isEmpty) else { return }
        guard let nextSong = peekNextSong() else { return }

        // Prefetch-Fenster erst nach der 5-Sekunden-Marke auffüllen.
        if currentTime >= 5 {
            refreshStreamCacheWindow()
        }

        // Gapless-Preload: 10s vor Ende (nur wenn Flag nicht gesetzt)
        guard !gaplessPreloadTriggered else { return }
        guard gaplessEnabled else { return }
        let preloadAt = duration - 10
        guard currentTime >= preloadAt else { return }
        guard let resolvedURL = resolveURL(for: nextSong) else { return }

        if resolvedURL.isFileURL {
            // Lokale Datei (Download oder Stream-Cache) — direkt an Engine übergeben
            gaplessPreloadSong = nextSong
            gaplessPreloadURL = resolvedURL
            gaplessPreloadTriggered = true
            engine.preloadForGapless(url: resolvedURL)
        } else if isTranscodedRemote(resolvedURL) {
            // Transcodierter Remote-Stream — Cache könnte noch laufen.
            // Flag sofort setzen um Re-Entry zu verhindern; async auf lokale Datei warten.
            gaplessPreloadSong = nextSong
            gaplessPreloadTriggered = true
            let songId = nextSong.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Kurz pollen bis Cache-Datei da ist (max ~8s in 200ms-Schritten)
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
                // Cache nicht rechtzeitig fertig — Flag zurücksetzen damit kein Gapless-Swap ausgelöst wird
                if self.gaplessPreloadSong?.id == songId {
                    self.gaplessPreloadTriggered = false
                    self.gaplessPreloadSong = nil
                    self.gaplessPreloadURL = nil
                }
            }
        } else if streamPreCacheEnabled {
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
                    self.gaplessPreloadURL = nil
                }
            }
        } else {
            // Raw Remote-Stream — direkt in AVQueuePlayer einreihen, Best-Effort
            gaplessPreloadSong = nextSong
            gaplessPreloadURL = resolvedURL
            gaplessPreloadTriggered = true
            engine.preloadForGapless(url: resolvedURL)
        }
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
                    let square = squareCropped(img)
                    let artwork = MPMediaItemArtwork(boundsSize: square.size) { _ in square }
                    self.currentArtwork = artwork
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updated[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
            #elseif os(macOS)
            // macOS: schlanker NSImage-Load wie in der bisherigen Desktop-App.
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
            // tvOS: schlanker UIImage-Load (kein plattformeigener Bild-Cache wie iOS/macOS).
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

    /// Favoriten-Status des laufenden Songs spiegeln (macOS-PlayerBar nutzt das;
    /// plattformneutral, da nur Queue-State angefasst wird).
    func setCurrentSongStarred(_ starred: Bool) {
        guard var song = currentSong else { return }
        song.starred = starred ? Date() : nil
        currentSong = song
        if queue.indices.contains(currentIndex) {
            queue[currentIndex].starred = song.starred
        }
    }


    private func applyPlaybackModeToNowPlayingInfo() {
        let cc = MPRemoteCommandCenter.shared()
        cc.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
        switch repeatMode {
        case .off: cc.changeRepeatModeCommand.currentRepeatType = .off
        case .one: cc.changeRepeatModeCommand.currentRepeatType = .one
        case .all: cc.changeRepeatModeCommand.currentRepeatType = .all
        }
    }

    private func updateNowPlayingPlaybackRate(_ rate: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTime(_ time: Double) {
        guard abs(time - lastReportedNowPlayingTime) >= 0.5 else { return }
        lastReportedNowPlayingTime = time
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func applyReplayGain(for song: Song) {
        guard replayGainEnabled, let rg = song.replayGain else {
            engine.setVolume(1.0)
            return
        }
        let useTrack = replayGainMode == "track"
        let gain: Float? = useTrack ? (rg.trackGain ?? rg.albumGain) : (rg.albumGain ?? rg.trackGain)
        guard let gain else {
            engine.setVolume(1.0)
            return
        }
        let linear = pow(10.0, gain / 20.0)
        let peak: Float? = useTrack ? rg.trackPeak : rg.albumPeak
        let volume: Float = peak.map { $0 > 0 ? min(linear, 1.0 / $0) : linear } ?? min(linear, 1.0)
        engine.setVolume(volume)
    }
}
