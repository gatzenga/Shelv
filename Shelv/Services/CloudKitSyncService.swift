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
    @Published var debugLogEntries: [String] = []
    @Published var recapCreationLog: [String] = []

    nonisolated init() {}

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    func appendLog(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logEntries.insert("[\(stamp)] \(message)", at: 0)
        if logEntries.count > 100 { logEntries.removeLast(logEntries.count - 100) }
    }

    func appendDebugLog(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        debugLogEntries.insert("[\(stamp)] \(message)", at: 0)
        if debugLogEntries.count > 500 { debugLogEntries.removeLast(debugLogEntries.count - 500) }
    }

    func appendRecapLog(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        recapCreationLog.insert("[\(stamp)] \(message)", at: 0)
        if recapCreationLog.count > 300 { recapCreationLog.removeLast(recapCreationLog.count - 300) }
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
    private let syncEnabledKey = "iCloudSyncEnabled"

    private var isZoneReady = false

    private var syncEnabled: Bool {
        if UserDefaults.standard.object(forKey: syncEnabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: syncEnabledKey)
    }

    /// Voraussetzungen für *jeden* iCloud-Sync-Pfad:
    /// - iCloud-Sync vom User aktiviert
    /// - Recap-Feature aktiviert (iCloud existiert nur für Recap-Daten)
    /// - Nicht im Offline-Modus (Server eh nicht erreichbar)
    private var canSync: Bool {
        guard syncEnabled else { return false }
        guard UserDefaults.standard.bool(forKey: "recapEnabled") else { return false }
        if UserDefaults.standard.bool(forKey: "offlineModeEnabled") { return false }
        return true
    }
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
        debug("[CloudKitSync] setup() starting")
        guard canSync else {
            debug("[CloudKitSync] setup() skipped — sync conditions not met (icloud/recap/offline)")
            return
        }
        let accountStatus = await updateAccountStatus()
        debug("[CloudKitSync] accountStatus = \(Self.describe(accountStatus))")
        startNetworkMonitor()
        guard accountStatus == .available else {
            debug("[CloudKitSync] Aborting setup – iCloud account not available (status=\(Self.describe(accountStatus)))")
            return
        }
        do {
            debug("[CloudKitSync] Ensuring zone exists...")
            try await ensureZoneExists()
            debug("[CloudKitSync] Zone ready: \(zoneID.zoneName)")
            await updatePendingCounts()
            log("Ready")
        } catch {
            debug("[CloudKitSync] Setup failed with error: \(error)")
            debug("[CloudKitSync] Setup error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                debug("[CloudKitSync] CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            log("Setup error: \(error.localizedDescription)", isError: true)
        }
    }

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task {
                await CloudKitSyncService.shared.syncNow()
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
            debug("[CloudKitSync] accountStatus() threw: \(error.localizedDescription)")
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
        debug("[CloudKitSync] Checking if zone exists...")
        guard !isZoneReady else {
            debug("[CloudKitSync] Zone already marked ready (in-memory flag)")
            return
        }
        do {
            debug("[CloudKitSync] Creating/saving zone \(zoneID.zoneName)...")
            let saved = try await db.save(CKRecordZone(zoneID: zoneID))
            debug("[CloudKitSync] Zone save returned: \(saved.zoneID)")
            isZoneReady = true
        } catch {
            debug("[CloudKitSync] Zone save FAILED: \(error)")
            debug("[CloudKitSync] Zone save error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                debug("[CloudKitSync] Zone CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            throw error
        }
    }

    // MARK: - Upload

    func uploadPendingEvents() async {
        guard canSync else { return }
        guard await status.accountAvailable else {
            debug("[CloudKitSync] uploadPendingEvents skipped – account not available")
            return
        }
        do {
            try await ensureZoneExists()
            while canSync {
                let unsynced = await PlayLogService.shared.fetchUnsynced(limit: 200)
                debug("[CloudKitSync] Pending events to upload: \(unsynced.count)")
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

                debug("[CloudKitSync] Sending modifyRecords with \(records.count) records...")
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
                            debug("[CloudKitSync] Save failure for \(recordID.recordName): \(err.localizedDescription)")
                        }
                    }
                }

                await PlayLogService.shared.markSynced(uuids: uploaded)
                await updatePendingCounts()
                debug("[CloudKitSync] Uploaded \(uploaded.count) events (\(failureCount) failures)")
                if failureCount > 0 {
                    log("Uploaded \(uploaded.count) plays (\(failureCount) failed)", isError: true)
                } else {
                    log("Uploaded \(uploaded.count) plays")
                }
                await MainActor.run { status.lastSyncDate = Date() }
                if uploaded.isEmpty { return }
            }
        } catch {
            debug("[CloudKitSync] Upload error: \(error)")
            debug("[CloudKitSync] Upload error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                debug("[CloudKitSync] Upload CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            log("Upload error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Download

    func downloadChanges() async {
        guard canSync else { return }
        guard await status.accountAvailable else {
            debug("[CloudKitSync] downloadChanges skipped – account not available")
            return
        }
        do {
            try await ensureZoneExists()
            let hasToken = changeToken != nil
            debug("[CloudKitSync] Fetching changes with token: \(hasToken ? "hasToken" : "noToken")")
            let (records, deletions, newToken) = try await fetchZoneChanges()
            debug("[CloudKitSync] Received \(records.count) new records, \(deletions.count) deletions")
            // Deletionen zuerst: verhindert, dass ein Add mit gleichem recordName
            // (z.B. Recap-Marker Reset + Neu-Erzeugung auf anderem Gerät) durch
            // eine nachfolgende Delete-Meldung wieder entfernt wird.
            var playsDel = 0, recapsDel = 0
            for (recordID, recordType) in deletions {
                switch recordType {
                case "PlayEvent": playsDel += 1
                case "RecapMarker": recapsDel += 1
                default: break
                }
                await handleDeletedRecord(id: recordID, type: recordType)
            }
            var playsIn = 0, recapsIn = 0
            for record in records {
                switch record.recordType {
                case "PlayEvent": playsIn += 1
                case "RecapMarker": recapsIn += 1
                default: break
                }
                await handleIncomingRecord(record)
            }
            if let token = newToken { changeToken = token }
            if playsIn + recapsIn > 0 {
                log("Downloaded \(playsIn) plays, \(recapsIn) recaps")
            }
            if playsDel + recapsDel > 0 {
                log("Deleted on other device: \(playsDel) plays, \(recapsDel) recaps")
            }
            await MainActor.run { status.lastSyncDate = Date() }
        } catch {
            debug("[CloudKitSync] Download error: \(error)")
            debug("[CloudKitSync] Download error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                debug("[CloudKitSync] Download CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            if isZoneNotFound(error) {
                await markLocalAsUnsyncedForActiveServer()
                changeToken = nil
                isZoneReady = false
                log("iCloud zone was reset on another device — marking local data for re-upload")
            } else if isChangeTokenExpired(error) {
                // Zone was wiped and recreated on another device (typical when that device
                // re-enabled sync in the same flow). Treat like zoneNotFound so our local
                // truth gets re-uploaded.
                await markLocalAsUnsyncedForActiveServer()
                changeToken = nil
                isZoneReady = false
                log("Change token expired — marking local data for re-upload")
            } else {
                log("Download error: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func fetchZoneChanges() async throws -> (changed: [CKRecord], deleted: [(CKRecord.ID, CKRecord.RecordType)], token: CKServerChangeToken?) {
        try await withCheckedThrowingContinuation { continuation in
            var changed: [CKRecord] = []
            var deleted: [(CKRecord.ID, CKRecord.RecordType)] = []
            var latestToken: CKServerChangeToken?
            var zoneError: Error?

            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = changeToken

            let op = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config]
            )
            op.fetchAllChanges = true

            op.recordWasChangedBlock = { _, result in
                if case .success(let record) = result { changed.append(record) }
            }

            op.recordWithIDWasDeletedBlock = { recordID, recordType in
                deleted.append((recordID, recordType))
            }

            op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                if let token { latestToken = token }
            }

            op.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (token, _, _)):
                    latestToken = token
                case .failure(let err):
                    zoneError = err
                }
            }

            op.fetchRecordZoneChangesResultBlock = { result in
                if let zoneError {
                    continuation.resume(throwing: zoneError)
                    return
                }
                switch result {
                case .success: continuation.resume(returning: (changed, deleted, latestToken))
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
            if let existing = await PlayLogService.shared.registryEntry(byCKRecordName: name) {
                guard existing.playlistId != playlistId else { return }
                // Same ckRecordName, different playlistId → Delete+Recreate-Flow auf anderem Gerät.
                // Alten Eintrag entfernen, neuen übernehmen.
                await PlayLogService.shared.deleteRegistryEntry(playlistId: existing.playlistId)
            }
            let isTest = (record["isTest"] as? Int64 ?? 0) == 1 || name.hasPrefix("test.")
            let entry = RecapRegistryRecord(
                playlistId: playlistId, serverId: serverId,
                periodType: periodType, periodStart: periodStart, periodEnd: periodEnd,
                ckRecordName: name, isTest: isTest
            )
            await PlayLogService.shared.registerPlaylist(entry)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
            }

        default:
            break
        }
    }

    private func handleDeletedRecord(id: CKRecord.ID, type: CKRecord.RecordType) async {
        switch type {
        case "RecapMarker":
            if let entry = await PlayLogService.shared.registryEntry(byCKRecordName: id.recordName),
               entry.periodType == RecapPeriod.PeriodType.week.rawValue,
               !entry.isTest {
                let periodStart = entry.periodStart
                await MainActor.run { RecapProcessedWeeks.insert(periodStart) }
            }
            await PlayLogService.shared.deleteRegistryEntry(byCKRecordName: id.recordName)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
            }
        case "PlayEvent":
            await PlayLogService.shared.deletePlayLog(uuid: id.recordName)
            await updatePendingCounts()
        default:
            break
        }
    }

    // MARK: - RecapMarker

    func saveRecapMarker(_ entry: RecapRegistryRecord, periodKey: String) async throws -> RecapMarkerSaveResult {
        guard canSync else { return .created }
        try await ensureZoneExists()
        let recordName = makeRecapMarkerRecordName(serverId: entry.serverId, periodKey: periodKey, isTest: entry.isTest)
        let rid = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = CKRecord(recordType: "RecapMarker", recordID: rid)
        record["serverId"]    = entry.serverId
        record["playlistId"]  = entry.playlistId
        record["periodType"]  = entry.periodType
        record["periodStart"] = entry.periodStart
        record["periodEnd"]   = entry.periodEnd
        record["isTest"]      = entry.isTest ? 1 : 0

        await MainActor.run { status.isSyncing = true }
        log("Syncing…")

        do {
            _ = try await db.save(record)
            await PlayLogService.shared.updateRegistryCKRecordName(
                playlistId: entry.playlistId, ckRecordName: recordName
            )
            await MainActor.run {
                status.lastSyncDate = Date()
                status.isSyncing = false
            }
            log("Recap uploaded")
            return .created
        } catch let err as CKError where err.code == .serverRecordChanged {
            await MainActor.run { status.isSyncing = false }
            if let server = err.serverRecord, let existing = server["playlistId"] as? String {
                return .conflict(existingPlaylistId: existing)
            }
            throw err
        } catch {
            await MainActor.run { status.isSyncing = false }
            log("Recap upload failed: \(error.localizedDescription)", isError: true)
            throw error
        }
    }

    func fetchRecapMarker(serverId: String, periodKey: String, isTest: Bool = false) async -> RecapRegistryRecord? {
        guard canSync else { return nil }
        let recordName = makeRecapMarkerRecordName(serverId: serverId, periodKey: periodKey, isTest: isTest)
        let rid = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        guard let record = try? await db.record(for: rid) else { return nil }
        guard
            let playlistId  = record["playlistId"]  as? String,
            let serverId    = record["serverId"]     as? String,
            let periodType  = record["periodType"]   as? String,
            let periodStart = record["periodStart"]  as? Double,
            let periodEnd   = record["periodEnd"]    as? Double
        else { return nil }
        let testFlag = (record["isTest"] as? Int64 ?? 0) == 1 || recordName.hasPrefix("test.")
        return RecapRegistryRecord(
            playlistId: playlistId, serverId: serverId,
            periodType: periodType, periodStart: periodStart, periodEnd: periodEnd,
            ckRecordName: recordName, isTest: testFlag
        )
    }

    func deleteRecapMarker(ckRecordName: String, force: Bool = false) async {
        guard syncEnabled || force else { return }
        await MainActor.run { status.isSyncing = true }
        log("Syncing…")
        let rid = CKRecord.ID(recordName: ckRecordName, zoneID: zoneID)
        do {
            _ = try await db.modifyRecords(saving: [], deleting: [rid])
            await MainActor.run {
                status.lastSyncDate = Date()
                status.isSyncing = false
            }
            log("Recap deleted")
        } catch {
            await MainActor.run { status.isSyncing = false }
            log("Recap deletion failed: \(error.localizedDescription)", isError: true)
        }
    }

    func deletePlayEvent(uuid: String, force: Bool = false) async {
        guard syncEnabled || force else { return }
        await MainActor.run { status.isSyncing = true }
        log("Syncing…")
        let rid = CKRecord.ID(recordName: uuid, zoneID: zoneID)
        do {
            _ = try await db.modifyRecords(saving: [], deleting: [rid])
            await MainActor.run {
                status.lastSyncDate = Date()
                status.isSyncing = false
            }
            log("Play event deleted")
        } catch {
            await MainActor.run { status.isSyncing = false }
            log("Play event deletion failed: \(error.localizedDescription)", isError: true)
        }
    }

    func deletePlayEvents(uuids: [String], force: Bool = false) async {
        guard syncEnabled || force else { return }
        guard !uuids.isEmpty else { return }
        await MainActor.run { status.isSyncing = true }
        log("Syncing…")
        let rids = uuids.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        var failed = 0
        for start in stride(from: 0, to: rids.count, by: 400) {
            let chunk = Array(rids[start..<min(start + 400, rids.count)])
            do {
                _ = try await db.modifyRecords(saving: [], deleting: chunk)
            } catch {
                failed += chunk.count
            }
        }
        await MainActor.run {
            status.lastSyncDate = Date()
            status.isSyncing = false
        }
        if failed == 0 {
            log("Deleted \(uuids.count) play events")
        } else {
            log("Deleted \(uuids.count - failed) play events, \(failed) failed", isError: true)
        }
    }

    func deleteZone(force: Bool = false) async {
        guard syncEnabled || force else { return }
        await MainActor.run { status.isSyncing = true }
        log("Deleting iCloud zone…")
        do {
            _ = try await db.deleteRecordZone(withID: zoneID)
            isZoneReady = false
            changeToken = nil
            await MainActor.run {
                status.lastSyncDate = Date()
                status.isSyncing = false
            }
            log("iCloud zone deleted")
        } catch {
            await MainActor.run { status.isSyncing = false }
            if let ck = error as? CKError, ck.code == .zoneNotFound {
                isZoneReady = false
                changeToken = nil
                log("iCloud zone already gone")
            } else {
                log("Zone deletion failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func markLocalAsUnsyncedForActiveServer() async {
        let sid: String = await MainActor.run {
            SubsonicAPIService.shared.activeServer?.stableId ?? ""
        }
        guard !sid.isEmpty else { return }
        await PlayLogService.shared.markServerUnsyncedForReUpload(serverId: sid)
        await updatePendingCounts()
    }

    func deleteRecapMarkers(serverId: String, force: Bool = false) async {
        guard syncEnabled || force else { return }
        let entries = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        let ids = entries.compactMap { e -> CKRecord.ID? in
            guard let name = e.ckRecordName else { return nil }
            return CKRecord.ID(recordName: name, zoneID: zoneID)
        }
        guard !ids.isEmpty else { return }
        await MainActor.run { status.isSyncing = true }
        log("Syncing…")
        do {
            _ = try await db.modifyRecords(saving: [], deleting: ids)
            await MainActor.run {
                status.lastSyncDate = Date()
                status.isSyncing = false
            }
            log("Deleted \(ids.count) recaps")
        } catch {
            await MainActor.run { status.isSyncing = false }
            log("Recap deletion failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func makeRecapMarkerRecordName(serverId: String, periodKey: String, isTest: Bool = false) -> String {
        let base = "\(serverId.lowercased()).\(periodKey)"
        return isTest ? "test.\(base)" : base
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
        guard canSync else { return }
        log("Syncing…")
        await uploadPendingEvents()
        await downloadChanges()
        await uploadPendingEvents()
        await reuploadAllRecapMarkers()
        await flushScrobbleQueue()
        log("Sync done")
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

    func resetChangeToken() {
        changeToken = nil
        isZoneReady = false
    }

    func handleSyncEnabledChange() async {
        guard syncEnabled else {
            log("iCloud sync disabled")
            return
        }
        log("iCloud sync enabled — purging iCloud and re-uploading local truth")
        await setup()
        // Wipe iCloud so stale markers (from sync-off periods) can't be adopted.
        // Local data is preserved; markServerUnsyncedForReUpload re-flags everything
        // for re-upload. Other devices detect zoneNotFound on next sync and do the same.
        await deleteZone(force: true)
        await markLocalAsUnsyncedForActiveServer()
        resetChangeToken()
        await uploadPendingEvents()
        await reuploadAllRecapMarkers()
        await downloadChanges()
        await flushScrobbleQueue()
    }

    private func reuploadAllRecapMarkers() async {
        await reuploadRecapMarkers(onlyLocalOnly: false)
    }

    private func reuploadRecapMarkers(onlyLocalOnly: Bool) async {
        let stableId = await MainActor.run { SubsonicAPIService.shared.activeServer?.stableId } ?? ""
        guard !stableId.isEmpty else { return }
        let all = await PlayLogService.shared.allRegistryEntries(serverId: stableId)
        let entries = onlyLocalOnly ? all.filter { $0.ckRecordName == nil } : all
        guard !entries.isEmpty else { return }
        if onlyLocalOnly {
            log("Reconciling \(entries.count) local-only recap marker(s)")
        }

        let conflicts: [(entry: RecapRegistryRecord, existingPlaylistId: String, periodKey: String)] = await withTaskGroup(
            of: (RecapRegistryRecord, String, String)?.self
        ) { group in
            let maxConcurrent = 4
            var iterator = entries.makeIterator()
            var active = 0

            @Sendable func taskFor(_ entry: RecapRegistryRecord) async -> (RecapRegistryRecord, String, String)? {
                guard let type = RecapPeriod.PeriodType(rawValue: entry.periodType) else { return nil }
                let period = RecapPeriod(
                    type: type,
                    start: Date(timeIntervalSince1970: entry.periodStart),
                    end: Date(timeIntervalSince1970: entry.periodEnd)
                )
                let periodKey = await MainActor.run { period.periodKey }
                guard let result = try? await CloudKitSyncService.shared.saveRecapMarker(entry, periodKey: periodKey) else { return nil }
                if case .conflict(let existingPlaylistId) = result, existingPlaylistId != entry.playlistId {
                    return (entry, existingPlaylistId, periodKey)
                }
                return nil
            }

            while active < maxConcurrent, let entry = iterator.next() {
                group.addTask { await taskFor(entry) }
                active += 1
            }

            var results: [(RecapRegistryRecord, String, String)] = []
            while let result = await group.next() {
                if let r = result { results.append(r) }
                if let next = iterator.next() {
                    group.addTask { await taskFor(next) }
                }
            }
            return results
        }

        for conflict in conflicts {
            let recordName = makeRecapMarkerRecordName(serverId: stableId, periodKey: conflict.periodKey, isTest: conflict.entry.isTest)

            if onlyLocalOnly {
                let remoteExists = (try? await SubsonicAPIService.shared.getPlaylist(id: conflict.existingPlaylistId)) != nil
                if remoteExists {
                    CloudKitSyncService.debugLog("[Reupload] conflict: iCloud playlistId=\(conflict.existingPlaylistId) exists on Navidrome — adopting, keeping local \(conflict.entry.playlistId) as orphan")
                    let updated = RecapRegistryRecord(
                        playlistId: conflict.existingPlaylistId,
                        serverId: conflict.entry.serverId,
                        periodType: conflict.entry.periodType,
                        periodStart: conflict.entry.periodStart,
                        periodEnd: conflict.entry.periodEnd,
                        ckRecordName: recordName,
                        isTest: conflict.entry.isTest
                    )
                    await PlayLogService.shared.deleteRegistryEntry(playlistId: conflict.entry.playlistId)
                    await PlayLogService.shared.registerPlaylist(updated)
                } else {
                    CloudKitSyncService.debugLog("[Reupload] conflict: iCloud playlistId=\(conflict.existingPlaylistId) MISSING on Navidrome — keeping local \(conflict.entry.playlistId), clearing stale iCloud marker")
                    await deleteRecapMarker(ckRecordName: recordName)
                    var entry = conflict.entry
                    entry.ckRecordName = nil
                    _ = try? await saveRecapMarker(entry, periodKey: conflict.periodKey)
                }
            } else {
                CloudKitSyncService.debugLog("[Reupload] conflict (full): iCloud has playlistId=\(conflict.existingPlaylistId), local had \(conflict.entry.playlistId) — adopting iCloud")
                try? await SubsonicAPIService.shared.deletePlaylist(id: conflict.entry.playlistId)
                let updated = RecapRegistryRecord(
                    playlistId: conflict.existingPlaylistId,
                    serverId: conflict.entry.serverId,
                    periodType: conflict.entry.periodType,
                    periodStart: conflict.entry.periodStart,
                    periodEnd: conflict.entry.periodEnd,
                    ckRecordName: recordName,
                    isTest: conflict.entry.isTest
                )
                await PlayLogService.shared.deleteRegistryEntry(playlistId: conflict.entry.playlistId)
                await PlayLogService.shared.registerPlaylist(updated)
            }
        }
    }

    // MARK: - Helpers

    private func isZoneNotFound(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        return ck.code == .zoneNotFound || ck.code == .userDeletedZone
    }

    private func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        return ck.code == .changeTokenExpired
    }

    private func isChangeTokenError(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        return ck.code == .changeTokenExpired || ck.code == .zoneNotFound
    }

    private func log(_ message: String, isError: Bool = false) {
        print("[CloudKitSync] \(message)")
        let msg = message
        Task { @MainActor in
            status.appendLog(msg)
            status.appendDebugLog("[CloudKitSync] \(msg)")
            if isError { status.lastError = msg }
        }
    }

    private func debug(_ message: String) {
        print(message)
        let msg = message
        Task { @MainActor in
            status.appendDebugLog(msg)
        }
    }

    nonisolated static func debugLog(_ message: String) {
        print(message)
        let msg = message
        Task { @MainActor in
            CloudKitSyncService.shared.status.appendDebugLog(msg)
        }
    }

    nonisolated static func recapLog(_ message: String) {
        print(message)
        let msg = message
        Task { @MainActor in
            CloudKitSyncService.shared.status.appendRecapLog(msg)
        }
    }
}

// MARK: - Errors

enum CKSyncError: LocalizedError {
    case timeout
    var errorDescription: String? { "iCloud-Sync Timeout" }
}
