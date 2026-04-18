import Foundation
import Combine

// Beobachtet AudioPlayerService rein passiv via Combine — greift nie aktiv ein.
final class PlayTracker {
    static let shared = PlayTracker()

    private var cancellables = Set<AnyCancellable>()
    private let player = AudioPlayerService.shared

    private var trackedSongId: String?
    private var trackedServerId: String?
    private var trackedDuration: Double = 0
    private var playedSeconds: Double = 0
    private var lastTime: Double = -1

    private init() {
        // Song-Wechsel: vorherigen Song finalisieren, neuen starten
        player.$currentSong
            .receive(on: RunLoop.main)
            .sink { [weak self] newSong in
                self?.finalize()
                if let song = newSong {
                    self?.startTracking(song: song)
                }
            }
            .store(in: &cancellables)

        // Zeit-Akkumulation via timePublisher
        player.timePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] (time, _) in
                guard let self, self.player.isPlaying, !self.player.isSeeking else { return }
                let delta = time - self.lastTime
                if self.lastTime >= 0 && delta > 0 && delta < 2.0 {
                    self.playedSeconds += delta
                }
                self.lastTime = time
            }
            .store(in: &cancellables)

        // Seek: lastTime zurücksetzen damit kein falscher Delta gezählt wird
        player.$isSeeking
            .receive(on: RunLoop.main)
            .sink { [weak self] seeking in
                if seeking { self?.lastTime = -1 }
            }
            .store(in: &cancellables)
    }

    private func startTracking(song: Song) {
        trackedSongId = song.id
        trackedServerId = SubsonicAPIService.shared.activeServer?.stableId
        trackedDuration = song.duration.map { Double($0) } ?? 0
        playedSeconds = 0
        lastTime = -1
    }

    private func finalize() {
        guard let songId = trackedSongId,
              let serverId = trackedServerId,
              trackedDuration > 0,
              UserDefaults.standard.bool(forKey: "recapEnabled")
        else {
            reset()
            return
        }
        let pct = Double(UserDefaults.standard.integer(forKey: "recapThreshold"))
        let threshold = pct > 0 ? pct / 100.0 : 0.3
        if playedSeconds / trackedDuration >= threshold {
            let dur = trackedDuration
            Task.detached(priority: .utility) {
                await PlayLogService.shared.log(songId: songId, serverId: serverId, songDuration: dur)
                await CloudKitSyncService.shared.uploadPendingEvents()
            }
        }
        reset()
    }

    private func reset() {
        trackedSongId = nil
        trackedServerId = nil
        trackedDuration = 0
        playedSeconds = 0
        lastTime = -1
    }
}
