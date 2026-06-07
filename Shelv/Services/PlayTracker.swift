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
              trackedDuration > 0
        else {
            reset()
            return
        }
        let pct = Double(UserDefaults.standard.integer(forKey: "recapThreshold"))
        let threshold = pct > 0 ? pct / 100.0 : 0.3
        if playedSeconds / trackedDuration >= threshold {
            // Server-Scrobble: Song gilt ab der eingestellten Schwelle als gehört
            // (submission=true → Play-Count auf Navidrome). Bei Fehler in die
            // scrobble_queue für späteren Flush.
            let scrobbleAt = Date().timeIntervalSince1970
            Task.detached(priority: .utility) {
                do {
                    try await SubsonicAPIService.shared.scrobble(songId: songId, playedAt: scrobbleAt)
                } catch {
                    await PlayLogService.shared.addPendingScrobble(
                        songId: songId, serverId: serverId, playedAt: scrobbleAt
                    )
                }
            }
            // Play-Log: immer schreiben — die SQLite-DB ist unabhängig von Recap.
            // Recap, Mixe und Insights sind allesamt nur Konsumenten dieser Daten.
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
