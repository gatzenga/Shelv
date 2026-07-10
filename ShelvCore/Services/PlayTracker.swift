import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Beobachtet den gemeinsamen Player und persistiert einen Play beim erstmaligen
/// Erreichen der Hörschwelle. Die Audioquelle (Stream, Precache oder Download)
/// spielt dabei bewusst keine Rolle.
@MainActor
final class PlayTracker {
    static let shared = PlayTracker()

    private var cancellables = Set<AnyCancellable>()
    private let player = AudioPlayerService.shared

    private var trackedSongId: String?
    private var trackedServerId: String?
    private var trackedServerConfigId: String?
    private var trackedDuration: Double = 0
    private var playedSeconds: Double = 0
    private var lastTime: Double = -1
    private var hasRecordedCurrentPlay = false
    private var trackingToken = UUID()

    private init() {
        // Eine neue logische Wiedergabe wird explizit vom Player gemeldet. Dadurch
        // lösen reine Metadatenänderungen am currentSong keinen zweiten Play aus.
        player.playbackStartedPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.finalize()
                self?.startTracking(event)
            }
            .store(in: &cancellables)

        // Stop, Queue-Ende oder Wechsel zu Radio finalisiert die aktuelle Session.
        player.$currentSong
            .receive(on: RunLoop.main)
            .sink { [weak self] song in
                if song == nil { self?.finalize() }
            }
            .store(in: &cancellables)

        player.timePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] (time, _) in
                guard let self, self.player.isPlaying, !self.player.isSeeking else { return }
                let delta = time - self.lastTime
                if self.lastTime >= 0 && delta > 0 && delta < 2.0 {
                    self.playedSeconds += delta
                    self.recordPlayIfNeeded()
                }
                self.lastTime = time
            }
            .store(in: &cancellables)

        player.$isSeeking
            .receive(on: RunLoop.main)
            .sink { [weak self] seeking in
                if seeking { self?.lastTime = -1 }
            }
            .store(in: &cancellables)

        // Scrobble-Outbox ist unabhängig von CloudKit und reagiert direkt auf Netzrückkehr.
        NotificationCenter.default.publisher(for: .networkStatusChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard NetworkStatus.shared.hasNetwork else { return }
                self?.handleConnectivityAvailable()
            }
            .store(in: &cancellables)

        OfflineModeService.shared.$isOffline
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isOffline in
                if !isOffline { self?.handleConnectivityAvailable() }
            }
            .store(in: &cancellables)

        #if canImport(UIKit)
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.publisher(for: didBecomeActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleConnectivityAvailable() }
            .store(in: &cancellables)

        Task { [weak self] in
            await ScrobbleService.shared.setup()
            self?.handleConnectivityAvailable()
        }
    }

    private func startTracking(_ event: PlaybackTrackingStart) {
        trackedSongId = event.song.id
        trackedServerConfigId = event.serverConfigId
        trackedServerId = event.serverId
        trackedDuration = event.song.duration.map(Double.init) ?? 0
        playedSeconds = 0
        lastTime = -1
        hasRecordedCurrentPlay = false
        trackingToken = UUID()
    }

    private func recordPlayIfNeeded() {
        guard !hasRecordedCurrentPlay,
              let songId = trackedSongId,
              let serverId = trackedServerId,
              let serverConfigId = trackedServerConfigId,
              trackedDuration > 0
        else { return }

        let configuredPercent = Double(UserDefaults.standard.integer(forKey: "recapThreshold"))
        let threshold = configuredPercent > 0 ? configuredPercent / 100.0 : 0.3
        guard playedSeconds / trackedDuration >= threshold else { return }

        hasRecordedCurrentPlay = true
        let token = trackingToken
        let playedAt = Date().timeIntervalSince1970
        let duration = trackedDuration

        Task { [weak self] in
            let recorded = await ScrobbleService.shared.recordPlay(
                songId: songId,
                serverId: serverId,
                serverConfigId: serverConfigId,
                playedAt: playedAt,
                songDuration: duration
            )
            guard recorded else {
                if self?.trackingToken == token {
                    self?.hasRecordedCurrentPlay = false
                }
                return
            }
            await CloudKitSyncService.shared.uploadPendingEvents()
        }
    }

    private func finalize() {
        recordPlayIfNeeded()
        reset()
    }

    private func handleConnectivityAvailable() {
        guard NetworkStatus.shared.hasNetwork, !OfflineModeService.shared.isOffline else { return }
        player.refreshNavidromeNowPlaying()
        Task { await ScrobbleService.shared.flushPendingScrobbles() }
    }

    private func reset() {
        trackedSongId = nil
        trackedServerId = nil
        trackedServerConfigId = nil
        trackedDuration = 0
        playedSeconds = 0
        lastTime = -1
        hasRecordedCurrentPlay = false
        trackingToken = UUID()
    }
}
