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
    private var uploadDebounceTask: Task<Void, Never>?
    private var uploadWorkerTask: Task<Void, Never>?
    private var pendingUploadRequest: UploadRequest?
    private var uploadGeneration: UInt64 = 0
    private var contextRevision: UInt64 = 0
    private var checkGeneration: UInt64 = 0
    private var activeCheck: RemoteCheckToken?
    private var activeCheckWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastCheckContext: QueueSyncContext?
    private var lastCheckContextRevision: UInt64?
    private var lastCheckAt: Date?
    private var isRemoteOperationRunning = false
    private var remoteOperationWaiters: [CheckedContinuation<Void, Never>] = []

    private struct QueueSyncContext: Sendable {
        let mode: QueueSyncMode
        let serverId: String

        func matches(_ other: QueueSyncContext) -> Bool {
            mode.rawValue == other.mode.rawValue && serverId == other.serverId
        }
    }

    private struct UploadRequest: Sendable {
        let generation: UInt64
        let contextRevision: UInt64
        let context: QueueSyncContext
    }

    private struct RemoteCheckToken: Sendable {
        let generation: UInt64
        let contextRevision: UInt64
        let context: QueueSyncContext
    }

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    /// Leert das Queue-Sync-Log (Clear-Button in der Log-Ansicht).
    func clearLog() { logEntries.removeAll() }

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
    private func uploadFingerprintKey(_ serverId: String) -> String { "shelv_queuesync_uploadfp_\(serverId)" }

    private func lastKnownSignature(_ serverId: String) -> String? {
        UserDefaults.standard.string(forKey: knownKey(serverId))
    }
    private func setLastKnownSignature(_ sig: String, serverId: String) {
        UserDefaults.standard.set(sig, forKey: knownKey(serverId))
    }
    private func lastUploadFingerprint(_ serverId: String) -> String? {
        UserDefaults.standard.string(forKey: uploadFingerprintKey(serverId))
    }
    private func setLastUploadFingerprint(_ fingerprint: String, serverId: String) {
        UserDefaults.standard.set(fingerprint, forKey: uploadFingerprintKey(serverId))
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
        guard let context = currentContext else { return }
        uploadDebounceTask?.cancel()
        uploadGeneration &+= 1
        let request = UploadRequest(
            generation: uploadGeneration,
            contextRevision: contextRevision,
            context: context
        )
        uploadDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.enqueueUpload(request)
        }
    }

    /// Sofortiger Upload (an Endpunkten: Pause, Background, Songwechsel) — nimmt die
    /// aktuelle Position mit.
    func flushUpload() {
        guard let context = currentContext else { return }
        uploadDebounceTask?.cancel()
        uploadDebounceTask = nil
        uploadGeneration &+= 1
        enqueueUpload(UploadRequest(
            generation: uploadGeneration,
            contextRevision: contextRevision,
            context: context
        ))
    }

    private func enqueueUpload(_ request: UploadRequest) {
        guard isCurrent(request) else { return }
        pendingUploadRequest = request
        guard uploadWorkerTask == nil else { return }
        uploadWorkerTask = Task { [weak self] in
            await self?.drainUploads()
        }
    }

    private func drainUploads() async {
        while let request = pendingUploadRequest {
            pendingUploadRequest = nil
            await performUpload(request)
        }
        uploadWorkerTask = nil
    }

    private func performUpload(_ request: UploadRequest) async {
        guard isCurrent(request) else { return }
        await acquireRemoteOperation()
        defer { releaseRemoteOperation() }
        guard isCurrent(request) else { return }
        let m = request.context.mode
        let serverId = request.context.serverId
        // Solange eine fremde Queue auf Entscheidung wartet, NICHT hochladen — sonst würde
        // der lokale Stand genau die Queue überschreiben, die gerade angeboten wird.
        guard pendingRemote == nil else { return }
        guard let snapshot = AudioPlayerService.shared.makeSnapshot(serverId: serverId) else { return }

        // Hashing, flattening and JSON encoding can scale with the complete queue.
        // Keep that work away from the MainActor; only the player snapshot itself
        // must be captured there.
        let preparation = await Task.detached(priority: .utility) {
            let flat = snapshot.flattenedForSubsonic()
            let outgoingSignature = (m == .subsonic) ? flat.signature : snapshot.signature
            return QueueUploadPreparation(
                outgoingFingerprint: (m == .icloud) ? snapshot.uploadFingerprint : outgoingSignature,
                flatSnapshot: flat,
                cloudPayload: m == .icloud ? try? JSONEncoder().encode(snapshot) : nil
            )
        }.value
        guard isCurrent(request) else { return }
        let outgoingFingerprint = preparation.outgoingFingerprint
        if outgoingFingerprint == lastUploadFingerprint(serverId) { return }

        switch m {
        case .off:
            return
        case .icloud:
            guard let payload = preparation.cloudPayload else { return }
            let ok = await CloudKitSyncService.shared.savePlayQueue(
                serverId: serverId,
                payload: payload,
                changedAt: snapshot.changedAt,
                signature: snapshot.signature
            )
            guard isCurrentContext(request) else { return }
            // Signatur nur bei bestätigtem Upload merken — sonst hielten wir einen Stand für
            // „eigen", der nie in iCloud landete.
            if ok {
                setLastKnownSignature(snapshot.signature, serverId: serverId)
                setLastUploadFingerprint(snapshot.uploadFingerprint, serverId: serverId)
                appendLog("Uploaded to iCloud (\(snapshot.queue.count) songs)")
            } else {
                appendLog("iCloud upload failed")
            }
        case .subsonic:
            let flat = preparation.flatSnapshot
            // Niemals eine leere Liste hochladen — das würde die serverseitige Queue (auch die
            // eines anderen Geräts) löschen.
            guard !flat.queue.isEmpty else { return }
            do {
                let serverContext = try await SubsonicAPIService.shared.resolvedActiveRequestContext(
                    expectedServerId: serverId
                )
                guard isCurrent(request) else { return }
                try await SubsonicAPIService.shared.savePlayQueue(
                    songIds: flat.queue.map(\.id),
                    current: flat.currentSongId,
                    positionMs: 0,
                    context: serverContext
                )
                guard isCurrentContext(request) else { return }
                setLastKnownSignature(flat.signature, serverId: serverId)
                setLastUploadFingerprint(flat.signature, serverId: serverId)
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
        guard let serverId = activeServerId else {
            appendLog("Check skipped — no active server (stableId empty)")
            return
        }
        guard !OfflineModeService.shared.isOffline else {
            pendingRemote = nil
            appendLog("Check skipped — offline mode")
            return
        }
        let context = QueueSyncContext(mode: m, serverId: serverId)
        if let activeCheck {
            if activeCheck.contextRevision == contextRevision,
               activeCheck.context.matches(context) {
                await withCheckedContinuation { continuation in
                    activeCheckWaiters.append(continuation)
                }
                return
            }
            invalidateContext()
        }
        // Trigger-Bursts (z.B. Netz-Flapping) nur im unveränderten Kontext zusammenfassen.
        if let last = lastCheckAt,
           lastCheckContextRevision == contextRevision,
           lastCheckContext?.matches(context) == true,
           Date().timeIntervalSince(last) < 2 {
            return
        }
        lastCheckAt = Date()
        lastCheckContext = context
        lastCheckContextRevision = contextRevision
        checkGeneration &+= 1
        let token = RemoteCheckToken(
            generation: checkGeneration,
            contextRevision: contextRevision,
            context: context
        )
        activeCheck = token
        defer { finishRemoteCheck(token) }
        await acquireRemoteOperation()
        defer { releaseRemoteOperation() }
        guard isCurrent(token) else { return }
        guard await serverIsReachableForRemoteQueueCheck() else {
            guard isCurrent(token) else { return }
            pendingRemote = nil
            appendLog("Check skipped — server unreachable")
            return
        }
        guard isCurrent(token) else { return }

        let remote: QueueSnapshot?
        switch m {
        case .off:
            return
        case .icloud:
            if let payload = await CloudKitSyncService.shared.fetchPlayQueuePayload(serverId: serverId) {
                guard isCurrent(token) else { return }
                remote = await Task.detached(priority: .utility) {
                    try? JSONDecoder().decode(QueueSnapshot.self, from: payload)
                }.value
                guard isCurrent(token) else { return }
            } else {
                guard isCurrent(token) else { return }
                remote = nil
            }
        case .subsonic:
            if let pq = try? await SubsonicAPIService.shared.getPlayQueue() {
                guard isCurrent(token) else { return }
                remote = Self.snapshot(fromSubsonic: pq, serverId: serverId)
            } else {
                guard isCurrent(token) else { return }
                remote = nil
            }
        }

        guard isCurrent(token) else { return }
        let source = (m == .icloud) ? "iCloud" : "Subsonic"
        guard let remote, !remote.isEmpty else {
            appendLog("Checked \(source) — no remote queue")
            return
        }
        let sig = await Task.detached(priority: .utility) { remote.signature }.value
        guard isCurrent(token) else { return }

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
            let localSig = await Task.detached(priority: .utility) {
                (m == .subsonic) ? local.flattenedForSubsonic().signature : local.signature
            }.value
            guard isCurrent(token) else { return }
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
        let fingerprint = (mode == .icloud) ? snap.uploadFingerprint : snap.flattenedForSubsonic().signature
        setLastUploadFingerprint(fingerprint, serverId: snap.serverId)
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

    /// Beim Server-Wechsel ausstehende Arbeit und einen alten Banner verwerfen.
    /// Ein bereits gesendeter Netzwerk-Request darf seriell fertiglaufen, damit ihn
    /// der nächste Upload nicht überholen und den Remote-Stand zurückdrehen kann.
    func handleServerChange() {
        invalidateContext()
    }

    func handleModeChange() {
        invalidateContext()
    }

    func handleOfflineModeChange() {
        invalidateContext()
    }

    private var currentContext: QueueSyncContext? {
        let m = mode
        guard m != .off,
              !OfflineModeService.shared.isOffline,
              let serverId = activeServerId else { return nil }
        return QueueSyncContext(mode: m, serverId: serverId)
    }

    private func isCurrent(_ request: UploadRequest) -> Bool {
        guard !Task.isCancelled,
              request.generation == uploadGeneration,
              isCurrentContext(request)
        else { return false }
        return true
    }

    private func isCurrentContext(_ request: UploadRequest) -> Bool {
        guard request.contextRevision == contextRevision,
              let currentContext else { return false }
        return request.context.matches(currentContext)
    }

    private func isCurrent(_ token: RemoteCheckToken) -> Bool {
        guard !Task.isCancelled,
              activeCheck?.generation == token.generation,
              token.contextRevision == contextRevision,
              let currentContext
        else { return false }
        return token.context.matches(currentContext)
    }

    private func invalidateContext() {
        contextRevision &+= 1
        uploadGeneration &+= 1
        uploadDebounceTask?.cancel()
        uploadDebounceTask = nil
        pendingUploadRequest = nil
        checkGeneration &+= 1
        activeCheck = nil
        let checkWaiters = activeCheckWaiters
        activeCheckWaiters.removeAll(keepingCapacity: true)
        checkWaiters.forEach { $0.resume() }
        lastCheckAt = nil
        lastCheckContext = nil
        lastCheckContextRevision = nil
        pendingRemote = nil
    }

    private func finishRemoteCheck(_ token: RemoteCheckToken) {
        guard activeCheck?.generation == token.generation else { return }
        activeCheck = nil
        let waiters = activeCheckWaiters
        activeCheckWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    private func acquireRemoteOperation() async {
        guard isRemoteOperationRunning else {
            isRemoteOperationRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            remoteOperationWaiters.append(continuation)
        }
    }

    private func releaseRemoteOperation() {
        guard !remoteOperationWaiters.isEmpty else {
            isRemoteOperationRunning = false
            return
        }
        let next = remoteOperationWaiters.removeFirst()
        next.resume()
    }

    private func serverIsReachableForRemoteQueueCheck() async -> Bool {
        do {
            try await SubsonicAPIService.shared.ping()
            return true
        } catch {
            return false
        }
    }
}

private nonisolated struct QueueUploadPreparation: Sendable {
    let outgoingFingerprint: String
    let flatSnapshot: QueueSnapshot
    let cloudPayload: Data?
}
