import Foundation
import Combine

/// Orchestriert den geräteübergreifenden Sync der Wiedergabe-Queue.
///
/// Routet je nach `QueueSyncMode` an Subsonic (`savePlayQueue`/`getPlayQueue`) oder
/// CloudKit. Lädt debounced bei Queue-Änderungen hoch, prüft beim App-Start/Foreground
/// auf eine fremde Remote-Queue und bietet sie via `pendingRemote` der UI als Banner an.
///
/// Selbst-Prompt-Schutz ohne Geräte-Identität: jedes Gerät merkt sich lokal die
/// Signatur des zuletzt selbst hochgeladenen bzw. übernommenen Stands. Stimmt die
/// Remote-Signatur damit überein, war es der eigene Stand → kein Prompt.
@MainActor
final class QueueSyncService: ObservableObject {
    static let shared = QueueSyncService()
    private init() {}

    /// Vom Banner beobachtet: liegt eine fremde, übernehmbare Queue vor?
    @Published var pendingRemote: QueueSnapshot?

    private let modeKey = "queueSyncMode"
    private var uploadTask: Task<Void, Never>?

    var mode: QueueSyncMode {
        QueueSyncMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .off
    }

    private var activeServerId: String? {
        let id = SubsonicAPIService.shared.activeServer?.stableId ?? ""
        return id.isEmpty ? nil : id
    }

    // MARK: - Signatur-Bookkeeping (pro Server, lokal)

    private func knownKey(_ serverId: String) -> String { "shelv_queuesync_known_\(serverId)" }
    private func dismissedKey(_ serverId: String) -> String { "shelv_queuesync_dismissed_\(serverId)" }

    private func lastKnownSignature(_ serverId: String) -> String? {
        UserDefaults.standard.string(forKey: knownKey(serverId))
    }
    private func setLastKnownSignature(_ sig: String, serverId: String) {
        UserDefaults.standard.set(sig, forKey: knownKey(serverId))
    }
    private func lastDismissedSignature(_ serverId: String) -> String? {
        UserDefaults.standard.string(forKey: dismissedKey(serverId))
    }
    private func setDismissedSignature(_ sig: String, serverId: String) {
        UserDefaults.standard.set(sig, forKey: dismissedKey(serverId))
    }

    // MARK: - Upload

    /// Debounced Upload (bei Queue-Mutationen). Mehrere schnelle Änderungen → ein Upload.
    func scheduleUpload() {
        guard mode != .off else { return }
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await self?.performUpload()
        }
    }

    /// Sofortiger Upload (an Endpunkten: Pause, Background, Songwechsel) — nimmt die
    /// aktuelle Position mit.
    func flushUpload() {
        guard mode != .off else { return }
        uploadTask?.cancel()
        Task { [weak self] in await self?.performUpload() }
    }

    private func performUpload() async {
        let m = mode
        guard m != .off else { return }
        guard let serverId = activeServerId else { return }
        guard let snapshot = AudioPlayerService.shared.makeSnapshot(serverId: serverId) else { return }

        switch m {
        case .off:
            return
        case .icloud:
            guard let payload = try? JSONEncoder().encode(snapshot) else { return }
            await CloudKitSyncService.shared.savePlayQueue(
                serverId: serverId,
                payload: payload,
                changedAt: snapshot.changedAt,
                signature: snapshot.signature
            )
            setLastKnownSignature(snapshot.signature, serverId: serverId)
        case .subsonic:
            let flat = snapshot.flattenedForSubsonic()
            do {
                try await SubsonicAPIService.shared.savePlayQueue(
                    songIds: flat.queue.map(\.id),
                    current: flat.currentSongId,
                    positionMs: flat.positionMs
                )
                setLastKnownSignature(flat.signature, serverId: serverId)
            } catch {
                // Nicht schlimm — der nächste Mutations-Upload versucht es erneut.
            }
        }
    }

    // MARK: - Remote-Check (Start + Foreground)

    /// Holt die Remote-Queue und zeigt sie via `pendingRemote` an, falls sie von einem
    /// anderen Gerät stammt (Signatur weder „bekannt" noch „abgelehnt" noch == lokal).
    func checkForRemoteQueue() async {
        let m = mode
        guard m != .off else { return }
        guard let serverId = activeServerId else { return }

        let remote: QueueSnapshot?
        switch m {
        case .off:
            return
        case .icloud:
            if let payload = await CloudKitSyncService.shared.fetchPlayQueuePayload(serverId: serverId) {
                remote = try? JSONDecoder().decode(QueueSnapshot.self, from: payload)
            } else {
                remote = nil
            }
        case .subsonic:
            if let pq = try? await SubsonicAPIService.shared.getPlayQueue() {
                remote = Self.snapshot(fromSubsonic: pq, serverId: serverId)
            } else {
                remote = nil
            }
        }

        guard let remote, !remote.isEmpty else { return }
        let sig = remote.signature

        // Eigener Stand (zuletzt hochgeladen/übernommen) oder bereits abgelehnt?
        if sig == lastKnownSignature(serverId) || sig == lastDismissedSignature(serverId) { return }

        // Belt-and-suspenders: identisch zur aktuellen lokalen Queue → kein Prompt.
        if let local = AudioPlayerService.shared.makeSnapshot(serverId: serverId) {
            let localSig = (m == .subsonic) ? local.flattenedForSubsonic().signature : local.signature
            if localSig == sig {
                setLastKnownSignature(sig, serverId: serverId)
                return
            }
        }

        pendingRemote = remote
    }

    /// Baut aus einer Subsonic-Antwort einen Snapshot (flache Liste, current als Index).
    private static func snapshot(fromSubsonic pq: SubsonicPlayQueue, serverId: String) -> QueueSnapshot {
        let idx = pq.currentSongId.flatMap { id in pq.songs.firstIndex(where: { $0.id == id }) } ?? 0
        return QueueSnapshot(
            queue: pq.songs,
            currentIndex: idx,
            playNextQueue: [],
            userQueue: [],
            truthAlbumQueue: [],
            truthPlayNextQueue: [],
            truthUserQueue: [],
            currentSongId: pq.currentSongId,
            positionMs: pq.positionMs,
            isShuffled: false,
            repeatMode: RepeatMode.off.rawValue,
            serverId: serverId,
            changedAt: 0
        )
    }

    // MARK: - Banner-Aktionen

    /// User übernimmt die Remote-Queue.
    func acceptPending() {
        guard let snap = pendingRemote else { return }
        AudioPlayerService.shared.apply(snap)
        setLastKnownSignature(snap.signature, serverId: snap.serverId)
        pendingRemote = nil
    }

    /// User lehnt ab — derselbe Stand fragt nicht erneut.
    func dismissPending() {
        guard let snap = pendingRemote else { return }
        setDismissedSignature(snap.signature, serverId: snap.serverId)
        pendingRemote = nil
    }

    /// Beim Server-Wechsel: laufenden Upload abbrechen und einen evtl. offenen Banner
    /// (der den alten Server betraf) verwerfen. Der neue Server wird separat geprüft.
    func handleServerChange() {
        uploadTask?.cancel()
        pendingRemote = nil
    }
}
