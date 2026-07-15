import Foundation

/// Gemeinsame Navidrome-Wiedergabemeldungen für iOS, tvOS und macOS.
/// Now Playing bleibt ephemer; echte Plays werden zuerst dauerhaft vorgemerkt
/// und anschließend unabhängig von CloudKit zugestellt.
actor ScrobbleService {
    static let shared = ScrobbleService()

    private enum DeliveryError: Error {
        case serverConfigurationMissing
        case credentialsMissing
    }

    private let delivery: ScrobbleDeliveryCoordinator

    private init() {
        delivery = ScrobbleDeliveryCoordinator(
            canDeliver: {
                await Self.canContactServer()
            },
            loadBatch: { afterId, limit in
                let records = await PlayLogService.shared.pendingScrobbles(
                    afterId: afterId,
                    limit: limit
                )
                return records.compactMap { record in
                    guard let id = record.id else { return nil }
                    return PendingScrobbleDelivery(
                        id: id,
                        songId: record.songId,
                        serverId: record.serverId,
                        serverConfigId: record.serverConfigId,
                        playedAt: record.playedAt,
                        retries: record.retries
                    )
                }
            },
            submit: { item in
                guard let target = await Self.resolveServer(
                    configId: item.serverConfigId,
                    legacyServerId: item.serverId,
                    requireActive: false
                ) else {
                    throw DeliveryError.serverConfigurationMissing
                }
                guard let password = target.password else {
                    throw DeliveryError.credentialsMissing
                }
                try await SubsonicAPIService.shared.scrobble(
                    songId: item.songId,
                    submission: true,
                    playedAt: item.playedAt,
                    server: target.server,
                    password: password
                )
            },
            markDelivered: { id in
                await PlayLogService.shared.markScrobbleDone(id: id)
            },
            markFailed: { id in
                await PlayLogService.shared.incrementScrobbleRetry(id: id)
            }
        )
    }

    func setup() async {
        await PlayLogService.shared.setup()
        await flushPendingScrobbles()
    }

    /// Meldet nur den aktuell noch laufenden Titel. Fehlversuche werden bewusst
    /// nicht gespeichert, damit nach einem Reconnect kein veraltetes Lied erscheint.
    func reportNowPlaying(songId: String, serverConfigId: String) async {
        guard await Self.canContactServer(), !Task.isCancelled else { return }
        guard let target = await Self.resolveServer(
            configId: serverConfigId,
            legacyServerId: nil,
            requireActive: true
        ), let password = target.password else { return }

        do {
            try await SubsonicAPIService.shared.scrobble(
                songId: songId,
                submission: false,
                server: target.server,
                password: password
            )
        } catch is CancellationError {
            return
        } catch {
            ConnectivityDebugLog.log(
                "now playing failed: song=\(songId), server=\(serverConfigId), error=\(ConnectivityDebugLog.short(error))"
            )
        }
    }

    /// Persistiert die Outbox immer vor dem Netzversuch; iOS/macOS gemeinsam mit
    /// dem PlayLog atomar, tvOS outbox-first im dauerhaften Journal.
    @discardableResult
    func recordPlay(
        songId: String,
        serverId: String,
        serverConfigId: String,
        playedAt: Double,
        songDuration: Double
    ) async -> Bool {
        await PlayLogService.shared.setup()
        let uuid = await PlayLogService.shared.recordPlayAndQueueScrobble(
            songId: songId,
            serverId: serverId,
            serverConfigId: serverConfigId,
            playedAt: playedAt,
            songDuration: songDuration
        )
        guard uuid != nil else { return false }
        await flushPendingScrobbles()
        return true
    }

    func flushPendingScrobbles() async {
        await PlayLogService.shared.setup()
        await delivery.flush()
    }

    private nonisolated static func canContactServer() async -> Bool {
        guard !Task.isCancelled else { return false }
        await NetworkStatus.shared.waitUntilReady()
        guard !Task.isCancelled, NetworkStatus.shared.hasNetwork else { return false }
        return await MainActor.run { !OfflineModeService.shared.isOffline }
    }

    private nonisolated static func resolveServer(
        configId: String?,
        legacyServerId: String?,
        requireActive: Bool
    ) async -> (server: SubsonicServer, password: String?)? {
        let selection: StoredServerCredentialSelection
        if let configId, let id = UUID(uuidString: configId) {
            selection = .configuration(id)
        } else if let legacyServerId, !legacyServerId.isEmpty {
            // Alte Queue-Zeilen kannten nur die Remote-ID. Der Store akzeptiert
            // sie nur, solange sie genau eine lokale Konfiguration bezeichnet.
            selection = .uniqueLegacyIdentifier(legacyServerId)
        } else {
            return nil
        }

        guard !Task.isCancelled,
              let snapshot = await ServerStore.shared.credentialSnapshot(
                for: selection,
                requireActive: requireActive
              ) else {
            return nil
        }
        guard !Task.isCancelled,
              await ServerStore.shared.isCredentialSnapshotCurrent(
                snapshot,
                selection: selection,
                requireActive: requireActive
              ) else {
            return nil
        }

        let password: String? = switch snapshot.lookup {
        case .available(let password): password
        case .missing, .protectedDataUnavailable, .failed: nil
        }
        return (snapshot.server, password)
    }
}
