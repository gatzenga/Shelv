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

    /// Nachvollziehbarkeits-Log (Upload/Download/Übernahme), von der Log-Ansicht beobachtet.
    @Published var logEntries: [String] = []

    private let modeKey = "queueSyncMode"
    private var uploadTask: Task<Void, Never>?
    private var isChecking = false

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private func appendLog(_ message: String) {
        let stamp = Self.logTimeFormatter.string(from: Date())
        logEntries.insert("[\(stamp)] \(message)", at: 0)
        if logEntries.count > 200 { logEntries.removeLast(logEntries.count - 200) }
        print("[QueueSync] \(message)")
    }

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
        // Solange eine fremde Queue auf Entscheidung wartet, NICHT hochladen — sonst würde
        // der lokale Stand genau die Queue überschreiben, die gerade angeboten wird.
        guard pendingRemote == nil else { return }
        guard let snapshot = AudioPlayerService.shared.makeSnapshot(serverId: serverId) else { return }

        // Signatur, die hochgeladen würde. Hat sich der Inhalt seit dem letzten Upload/der
        // letzten Übernahme NICHT geändert, nicht erneut hochladen. Verhindert, dass ein
        // spurious Upload (z.B. beim Foreground/Resume, wo saveState ebenfalls feuert) eine
        // NEUERE Remote-Queue eines anderen Geräts überschreibt (last-write-wins).
        let outgoingSig = (m == .subsonic) ? snapshot.flattenedForSubsonic().signature : snapshot.signature
        if outgoingSig == lastKnownSignature(serverId) { return }

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
            appendLog("Uploaded to iCloud (\(snapshot.queue.count) songs)")
        case .subsonic:
            let flat = snapshot.flattenedForSubsonic()
            do {
                try await SubsonicAPIService.shared.savePlayQueue(
                    songIds: flat.queue.map(\.id),
                    current: flat.currentSongId,
                    positionMs: flat.positionMs
                )
                setLastKnownSignature(flat.signature, serverId: serverId)
                appendLog("Uploaded to Subsonic (\(flat.queue.count) songs)")
            } catch {
                // Nicht schlimm — der nächste Mutations-Upload versucht es erneut.
                appendLog("Subsonic upload failed: \(error.localizedDescription)")
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
        // Überlappende Checks vermeiden (syncNow kann von mehreren Auslösern gleichzeitig kommen).
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

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

        let source = (m == .icloud) ? "iCloud" : "Subsonic"
        guard let remote, !remote.isEmpty else {
            appendLog("Checked \(source) — no remote queue")
            return
        }
        let sig = remote.signature

        // Eigener Stand (zuletzt hochgeladen/übernommen) oder bereits abgelehnt?
        if sig == lastKnownSignature(serverId) {
            appendLog("Downloaded from \(source) — matches own last state, no prompt")
            return
        }
        if sig == lastDismissedSignature(serverId) {
            appendLog("Downloaded from \(source) — already dismissed, no prompt")
            return
        }

        // Belt-and-suspenders: identisch zur aktuellen lokalen Queue → kein Prompt.
        if let local = AudioPlayerService.shared.makeSnapshot(serverId: serverId) {
            let localSig = (m == .subsonic) ? local.flattenedForSubsonic().signature : local.signature
            if localSig == sig {
                setLastKnownSignature(sig, serverId: serverId)
                appendLog("Downloaded from \(source) — identical to local queue, no prompt")
                return
            }
        }

        appendLog("Downloaded from \(source) — foreign queue (\(remote.queue.count) songs), prompting")
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
        appendLog("Took over remote queue (\(snap.queue.count) songs)")
        pendingRemote = nil
    }

    /// User lehnt ab — derselbe Stand fragt nicht erneut.
    func dismissPending() {
        guard let snap = pendingRemote else { return }
        setDismissedSignature(snap.signature, serverId: snap.serverId)
        appendLog("Dismissed remote queue")
        pendingRemote = nil
    }

    /// Beim Server-Wechsel: laufenden Upload abbrechen und einen evtl. offenen Banner
    /// (der den alten Server betraf) verwerfen. Der neue Server wird separat geprüft.
    func handleServerChange() {
        uploadTask?.cancel()
        pendingRemote = nil
    }
}
