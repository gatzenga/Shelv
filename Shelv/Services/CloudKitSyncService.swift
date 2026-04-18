import CloudKit
import Combine
import Foundation
import Network

// MARK: - Sync Status (UI-facing)
// Kein @MainActor — Publishes werden via MainActor.run vom Service dispatched.

final class CloudKitSyncStatus: ObservableObject {
    @Published var lastSyncDate: Date?
    @Published var isSyncing = false
    @Published var pendingUploads = 0
    @Published var pendingScrobbles = 0
    @Published var lastError: String?
    @Published var accountAvailable = true
    @Published var logEntries: [String] = []

    nonisolated init() {}

    func appendLog(_ message: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logEntries.insert("[\(stamp)] \(message)", at: 0)
        if logEntries.count > 100 { logEntries = Array(logEntries.prefix(100)) }
    }
}

// MARK: - RecapMarker Result

enum RecapMarkerSaveResult {
    case created
    case conflict(existingPlaylistId: String)
}

// MARK: - CloudKitSyncService

actor CloudKitSyncService {
    static let shared = CloudKitSyncService()

    nonisolated let status = CloudKitSyncStatus()

    private let container  = CKContainer(identifier: "iCloud.ch.vkugler.Shelv")
    private var db: CKDatabase { container.privateCloudDatabase }
    private let zoneID     = CKRecordZone.ID(zoneName: "ShelveRecapZone",
                                              ownerName: CKCurrentUserDefaultName)

    private let tokenKey    = "shelv_ck_zone_token"
    private let deviceIdKey = "shelv_device_id"

    private var isZoneReady = false
    // NWPathMonitor lebt im actor – kein Lifecycle-Problem auf SwiftUI-Structs
    nonisolated(unsafe) private var pathMonitor: NWPathMonitor?
    private init() {}

    // MARK: - Device ID

    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: deviceIdKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }

    // MARK: - Change Token

    private var changeToken: CKServerChangeToken? {
        get {
            guard let data = UserDefaults.standard.data(forKey: tokenKey) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        set {
            if let token = newValue,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: tokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tokenKey)
            }
        }
    }

    // MARK: - Setup

    func setup() async {
        print("[CloudKitSync] setup() starting")
        let accountStatus = await updateAccountStatus()
        print("[CloudKitSync] accountStatus = \(Self.describe(accountStatus))")
        startNetworkMonitor()
        guard accountStatus == .available else {
            print("[CloudKitSync] Aborting setup – iCloud account not available (status=\(Self.describe(accountStatus)))")
            return
        }
        do {
            print("[CloudKitSync] Ensuring zone exists...")
            try await ensureZoneExists()
            print("[CloudKitSync] Zone ready: \(zoneID.zoneName)")
            await updatePendingCounts()
            log("Bereit")
        } catch {
            print("[CloudKitSync] Setup failed with error: \(error)")
            print("[CloudKitSync] Setup error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                print("[CloudKitSync] CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            log("Setup-Fehler: \(error.localizedDescription)", isError: true)
        }
    }

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task {
                await CloudKitSyncService.shared.uploadPendingEvents()
                await CloudKitSyncService.shared.flushScrobbleQueue()
            }
        }
        monitor.start(queue: DispatchQueue(label: "ch.vkugler.shelv.netmonitor", qos: .utility))
        pathMonitor = monitor
    }

    // MARK: - Account

    @discardableResult
    func updateAccountStatus() async -> CKAccountStatus {
        do {
            let s = try await container.accountStatus()
            let available = s == .available
            await MainActor.run { status.accountAvailable = available }
            return s
        } catch {
            print("[CloudKitSync] accountStatus() threw: \(error.localizedDescription)")
            await MainActor.run { status.accountAvailable = false }
            return .couldNotDetermine
        }
    }

    private static func describe(_ s: CKAccountStatus) -> String {
        switch s {
        case .available:           return "available"
        case .noAccount:           return "noAccount"
        case .restricted:          return "restricted"
        case .couldNotDetermine:   return "couldNotDetermine"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        @unknown default:          return "unknown(\(s.rawValue))"
        }
    }

    // MARK: - Zone

    private func ensureZoneExists() async throws {
        print("[CloudKitSync] Checking if zone exists...")
        guard !isZoneReady else {
            print("[CloudKitSync] Zone already marked ready (in-memory flag)")
            return
        }
        do {
            print("[CloudKitSync] Creating/saving zone \(zoneID.zoneName)...")
            let saved = try await db.save(CKRecordZone(zoneID: zoneID))
            print("[CloudKitSync] Zone save returned: \(saved.zoneID)")
            isZoneReady = true
        } catch {
            print("[CloudKitSync] Zone save FAILED: \(error)")
            print("[CloudKitSync] Zone save error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                print("[CloudKitSync] Zone CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            throw error
        }
    }

    // MARK: - Upload

    func uploadPendingEvents() async {
        guard await status.accountAvailable else {
            print("[CloudKitSync] uploadPendingEvents skipped – account not available")
            return
        }
        do {
            try await ensureZoneExists()
            let unsynced = await PlayLogService.shared.fetchUnsynced(limit: 200)
            print("[CloudKitSync] Pending events to upload: \(unsynced.count)")
            guard !unsynced.isEmpty else { return }

            let did = deviceId
            let records: [CKRecord] = unsynced.compactMap { event in
                guard let uuid = event.uuid else { return nil }
                let rid = CKRecord.ID(recordName: uuid, zoneID: zoneID)
                let r = CKRecord(recordType: "PlayEvent", recordID: rid)
                r["uuid"]         = uuid
                r["songId"]       = event.songId
                r["serverId"]     = event.serverId
                r["playedAt"]     = event.playedAt
                r["songDuration"] = event.songDuration
                r["deviceId"]     = did
                return r
            }
            guard !records.isEmpty else { return }

            print("[CloudKitSync] Sending modifyRecords with \(records.count) records...")
            let saveResults = try await db.modifyRecords(
                saving: records, deleting: [],
                savePolicy: .allKeys, atomically: false
            ).saveResults

            var uploaded: [String] = []
            var failureCount = 0
            for (recordID, result) in saveResults {
                switch result {
                case .success:
                    uploaded.append(recordID.recordName)
                case .failure(let err):
                    if let ckErr = err as? CKError, ckErr.code == .serverRecordChanged {
                        uploaded.append(recordID.recordName)
                    } else {
                        failureCount += 1
                        print("[CloudKitSync] Save failure for \(recordID.recordName): \(err.localizedDescription)")
                    }
                }
            }

            await PlayLogService.shared.markSynced(uuids: uploaded)
            await updatePendingCounts()
            print("[CloudKitSync] Uploaded \(uploaded.count) events (\(failureCount) failures)")
            log("Hochgeladen: \(uploaded.count) Events")
            await MainActor.run { status.lastSyncDate = Date() }
        } catch {
            print("[CloudKitSync] Upload error: \(error)")
            print("[CloudKitSync] Upload error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                print("[CloudKitSync] Upload CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            log("Upload-Fehler: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Download

    func downloadChanges() async {
        guard await status.accountAvailable else {
            print("[CloudKitSync] downloadChanges skipped – account not available")
            return
        }
        do {
            try await ensureZoneExists()
            let hasToken = changeToken != nil
            print("[CloudKitSync] Fetching changes with token: \(hasToken ? "hasToken" : "noToken")")
            let (records, newToken) = try await fetchZoneChanges()
            print("[CloudKitSync] Received \(records.count) new records")
            for record in records {
                await handleIncomingRecord(record)
            }
            if let token = newToken { changeToken = token }
            if !records.isEmpty { log("Empfangen: \(records.count) Records") }
            await MainActor.run { status.lastSyncDate = Date() }
        } catch {
            print("[CloudKitSync] Download error: \(error)")
            print("[CloudKitSync] Download error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                print("[CloudKitSync] Download CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            if isChangeTokenError(error) {
                changeToken = nil
                log("Change-Token abgelaufen – nächster Sync holt alles neu")
            } else {
                log("Download-Fehler: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func fetchZoneChanges() async throws -> ([CKRecord], CKServerChangeToken?) {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [CKRecord] = []
            var latestToken: CKServerChangeToken?

            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = changeToken

            let op = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config]
            )
            op.fetchAllChanges = true

            op.recordWasChangedBlock = { _, result in
                if case .success(let record) = result { collected.append(record) }
            }

            op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                if let token { latestToken = token }
            }

            // recordZoneFetchResultBlock: Token aktualisieren, Fehler nicht selbst resumieren –
            // fetchRecordZoneChangesResultBlock ist der einzige Resumption-Punkt.
            op.recordZoneFetchResultBlock = { _, result in
                if case .success(let (token, _, _)) = result { latestToken = token }
            }

            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success: continuation.resume(returning: (collected, latestToken))
                case .failure(let err): continuation.resume(throwing: err)
                }
            }

            db.add(op)
        }
    }

    private func handleIncomingRecord(_ record: CKRecord) async {
        switch record.recordType {
        case "PlayEvent":
            guard
                let uuid       = record["uuid"]         as? String,
                let songId     = record["songId"]        as? String,
                let serverId   = record["serverId"]      as? String,
                let playedAt   = record["playedAt"]      as? Double,
                let duration   = record["songDuration"]  as? Double
            else { return }
            await PlayLogService.shared.insertIfNotExists(
                uuid: uuid, songId: songId, serverId: serverId,
                playedAt: playedAt, songDuration: duration
            )

        case "RecapMarker":
            guard
                let playlistId  = record["playlistId"]  as? String,
                let serverId    = record["serverId"]     as? String,
                let periodType  = record["periodType"]   as? String,
                let periodStart = record["periodStart"]  as? Double,
                let periodEnd   = record["periodEnd"]    as? Double
            else { return }
            let name = record.recordID.recordName
            guard await PlayLogService.shared.registryEntry(byCKRecordName: name) == nil else { return }
            let entry = RecapRegistryRecord(
                playlistId: playlistId, serverId: serverId,
                periodType: periodType, periodStart: periodStart, periodEnd: periodEnd,
                ckRecordName: name
            )
            await PlayLogService.shared.registerPlaylist(entry)

        default:
            break
        }
    }

    // MARK: - RecapMarker

    func saveRecapMarker(_ entry: RecapRegistryRecord, periodKey: String) async throws -> RecapMarkerSaveResult {
        try await ensureZoneExists()
        let recordName = makeRecapMarkerRecordName(serverId: entry.serverId, periodKey: periodKey)
        let rid = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = CKRecord(recordType: "RecapMarker", recordID: rid)
        record["serverId"]    = entry.serverId
        record["playlistId"]  = entry.playlistId
        record["periodType"]  = entry.periodType
        record["periodStart"] = entry.periodStart
        record["periodEnd"]   = entry.periodEnd

        do {
            _ = try await db.save(record)
            await PlayLogService.shared.updateRegistryCKRecordName(
                playlistId: entry.playlistId, ckRecordName: recordName
            )
            return .created
        } catch let err as CKError where err.code == .serverRecordChanged {
            if let server = err.serverRecord, let existing = server["playlistId"] as? String {
                return .conflict(existingPlaylistId: existing)
            }
            throw err
        }
    }

    func fetchRecapMarker(serverId: String, periodKey: String) async -> RecapRegistryRecord? {
        let recordName = makeRecapMarkerRecordName(serverId: serverId, periodKey: periodKey)
        let rid = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        guard let record = try? await db.record(for: rid) else { return nil }
        guard
            let playlistId  = record["playlistId"]  as? String,
            let serverId    = record["serverId"]     as? String,
            let periodType  = record["periodType"]   as? String,
            let periodStart = record["periodStart"]  as? Double,
            let periodEnd   = record["periodEnd"]    as? Double
        else { return nil }
        return RecapRegistryRecord(
            playlistId: playlistId, serverId: serverId,
            periodType: periodType, periodStart: periodStart, periodEnd: periodEnd,
            ckRecordName: recordName
        )
    }

    func deleteRecapMarkers(serverId: String) async {
        let entries = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        let ids = entries.compactMap { e -> CKRecord.ID? in
            guard let name = e.ckRecordName else { return nil }
            return CKRecord.ID(recordName: name, zoneID: zoneID)
        }
        guard !ids.isEmpty else { return }
        _ = try? await db.modifyRecords(saving: [], deleting: ids)
    }

    private func makeRecapMarkerRecordName(serverId: String, periodKey: String) -> String {
        "\(serverId.lowercased()).\(periodKey)"
    }

    // MARK: - Scrobble Queue

    func flushScrobbleQueue() async {
        let activeServerId = await MainActor.run { SubsonicAPIService.shared.activeServer?.stableId }
        let pending = await PlayLogService.shared.pendingScrobbles()
        await PlayLogService.shared.removeExhaustedScrobbles()

        for item in pending {
            guard let itemId = item.id else { continue }
            // Nur für aktiven Server – andere bleiben in der Queue bis Server-Wechsel
            guard item.serverId == activeServerId else { continue }
            do {
                try await SubsonicAPIService.shared.scrobble(songId: item.songId, playedAt: item.playedAt)
                await PlayLogService.shared.markScrobbleDone(id: itemId)
            } catch {
                await PlayLogService.shared.incrementScrobbleRetry(id: itemId)
            }
        }
        await updatePendingCounts()
    }

    func syncNow() async {
        let msgStart = await MainActor.run { tr("Syncing…", "Synchronisiere…") }
        let msgDone  = await MainActor.run { tr("Sync done", "Sync abgeschlossen") }
        log(msgStart)
        await uploadPendingEvents()
        await downloadChanges()
        await flushScrobbleQueue()
        log(msgDone)
    }

    // MARK: - flushAndWait (mit Timeout)

    func flushAndWait(timeout: TimeInterval = 60) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.uploadPendingEvents()
                await self.downloadChanges()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw CKSyncError.timeout
            }
            // Erste abgeschlossene Task gewinnt; die andere wird abgebrochen
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Pending Counts

    func updatePendingCounts() async {
        let uploads   = await PlayLogService.shared.pendingUploadCount()
        let scrobbles = await PlayLogService.shared.pendingScrobbleCount()
        await MainActor.run {
            status.pendingUploads   = uploads
            status.pendingScrobbles = scrobbles
        }
    }

    // MARK: - Helpers

    private func isChangeTokenError(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        return ck.code == .changeTokenExpired || ck.code == .zoneNotFound
    }

    private func log(_ message: String, isError: Bool = false) {
        print("[CloudKitSync] \(message)")
        let msg = message
        Task { @MainActor in
            status.appendLog(msg)
            if isError { status.lastError = msg }
        }
    }
}

// MARK: - Errors

enum CKSyncError: LocalizedError {
    case timeout
    var errorDescription: String? { "iCloud-Sync Timeout" }
}
