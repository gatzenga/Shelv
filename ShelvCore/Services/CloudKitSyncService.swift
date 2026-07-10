import CloudKit
import Combine
import Foundation
import Network

// MARK: - Sync Status (UI-facing)

@MainActor
final class CloudKitSyncStatus: ObservableObject {
    @Published var lastSyncDate: Date?
    @Published var isSyncing = false
    @Published var currentMessage: String?
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

private nonisolated struct CloudDownloadStats: Sendable {
    var playsDownloaded = 0
    var recapsDownloaded = 0
    var settingsDownloaded = 0
    var playsDeleted = 0
    var recapsDeleted = 0
    var settingsDeleted = 0

    mutating func add(_ other: CloudDownloadStats) {
        playsDownloaded += other.playsDownloaded
        recapsDownloaded += other.recapsDownloaded
        settingsDownloaded += other.settingsDownloaded
        playsDeleted += other.playsDeleted
        recapsDeleted += other.recapsDeleted
        settingsDeleted += other.settingsDeleted
    }
}

private enum CloudSyncCategory: String, CaseIterable {
    case playHistory
    case recap
    case lyricsServer
    case uiCustomizations

    nonisolated var displayName: String {
        switch self {
        case .playHistory: return "Play History"
        case .recap: return "Recap"
        case .lyricsServer: return "Lyrics Server"
        case .uiCustomizations: return "UI Customizations"
        }
    }

    nonisolated var tokenKey: String {
        switch self {
        case .playHistory: return "shelv_ck_zone_token_play_history"
        case .recap: return "shelv_ck_zone_token_recap"
        case .lyricsServer: return "shelv_ck_zone_token_lyrics_server"
        case .uiCustomizations: return "shelv_ck_zone_token_ui_customizations"
        }
    }

    nonisolated func handles(recordType: CKRecord.RecordType) -> Bool {
        switch self {
        case .playHistory:
            return recordType == "PlayEvent"
        case .recap:
            return recordType == "RecapMarker" || recordType == "RecapSettings"
        case .lyricsServer:
            return recordType == "LyricsServerSettings"
        case .uiCustomizations:
            return recordType == "UICustomizationSettings"
        }
    }
}

private nonisolated struct CloudUICustomizationPayload: Codable, Sendable {
    let schemaVersion: Int
    let values: [String: PersonalizationCloudValue]
}

// MARK: - CloudKitSyncService

actor CloudKitSyncService {
    static let shared = CloudKitSyncService()

    nonisolated let status = CloudKitSyncStatus()

    private let container  = CKContainer(identifier: "iCloud.ch.vkugler.Shelv")
    private var db: CKDatabase { container.privateCloudDatabase }
    private let zoneID     = CKRecordZone.ID(zoneName: "ShelveRecapZone",
                                              ownerName: CKCurrentUserDefaultName)

    private let legacyTokenKey = "shelv_ck_zone_token"
    private let deviceIdKey = "shelv_device_id"
    private let syncEnabledKey = "iCloudSyncEnabled"
    private let playHistorySyncEnabledKey = "iCloudSyncPlayHistoryEnabled"
    private let recapSyncEnabledKey = "iCloudSyncRecapEnabled"
    private let lyricsServerSyncEnabledKey = "iCloudSyncLyricsServerEnabled"
    private let radioStationsSyncEnabledKey = "iCloudSyncRadioStationsEnabled"
    private let uiCustomizationsSyncEnabledKey = "iCloudSyncUICustomizationsEnabled"
    private let queueSyncModeKey = "queueSyncMode"

    // Geteilte Recap-Retention (eine Wahrheit über alle Geräte, statt lokalem @AppStorage).
    // Singleton-Record in der Zone; Last-write-wins per updatedAt-Zeitstempel.
    private static let retentionRecordName = "recap_settings"
    private static let weeklyKey  = "recapWeeklyRetention"
    private static let monthlyKey = "recapMonthlyRetention"
    private static let yearlyKey  = "recapYearlyRetention"
    private let retentionUpdatedAtKey = "recap_retention_updated_at"
    private let retentionSyncedAtKey  = "recap_retention_synced_at"

    private static let lyricsServerRecordName = "lyrics_server_settings"
    private static let lyricsUseCustomKey = "useCustomLrcLibServer"
    private static let lyricsCustomURLKey = "customLrcLibBaseURL"
    private static let lyricsOnlineFallbackKey = LrcLibEndpoint.onlineFallbackEnabledKey
    private let lyricsServerUpdatedAtKey = "lyrics_server_updated_at"
    private let lyricsServerSyncedAtKey = "lyrics_server_synced_at"
    private let lyricsServerEchoUseCustomKey = "lyrics_server_echo_use_custom"
    private let lyricsServerEchoCustomURLKey = "lyrics_server_echo_custom_url"
    private let lyricsServerEchoOnlineFallbackKey = "lyrics_server_echo_online_fallback"
    private let lyricsServerEchoUpdatedAtKey = "lyrics_server_echo_updated_at"

    private static let uiCustomizationsRecordName = "ui_customization_settings"
    private let uiCustomizationsUpdatedAtKey = "ui_customizations_updated_at"
    private let uiCustomizationsSyncedAtKey = "ui_customizations_synced_at"

    private var isZoneReady = false
    private var lastDisabledLogAt: [String: Date] = [:]
    private let minimumVisibleStatusDuration: TimeInterval = 3
    private var isSyncWorkflowRunning = false
    private var isSyncNowQueued = false
    private var recapSyncFailureMessage: String?
    private var currentStatusChangedAt = Date.distantPast
    private var isApplyingRemoteUICustomizations = false
    private var lastUICustomizationSnapshot: [String: PersonalizationCloudValue]?

    private var syncEnabled: Bool {
        if UserDefaults.standard.object(forKey: syncEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: syncEnabledKey)
    }

    private var playHistorySyncEnabled: Bool {
        boolDefaultingToTrue(forKey: playHistorySyncEnabledKey)
    }

    private var recapSyncEnabled: Bool {
        boolDefaultingToTrue(forKey: recapSyncEnabledKey)
    }

    private var lyricsServerSyncEnabled: Bool {
        boolDefaultingToTrue(forKey: lyricsServerSyncEnabledKey)
    }

    private var radioStationsSyncEnabled: Bool {
        boolDefaultingToTrue(forKey: radioStationsSyncEnabledKey)
    }

    private var uiCustomizationsSyncEnabled: Bool {
        boolDefaultingToTrue(forKey: uiCustomizationsSyncEnabledKey)
    }

    private var offlineModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "offlineModeEnabled")
    }

    /// Voraussetzungen für *jeden* iCloud-Sync-Pfad:
    /// - iCloud-Sync vom User aktiviert
    /// - Nicht im Offline-Modus (Server eh nicht erreichbar)
    private var canSyncBase: Bool {
        guard syncEnabled else { return false }
        if offlineModeEnabled { return false }
        return true
    }

    private var canSync: Bool {
        canSyncBase && (
            CloudSyncCategory.allCases.contains { isEnabled($0) }
                || radioStationsSyncEnabled
        )
    }

    private func boolDefaultingToTrue(forKey key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func isEnabled(_ category: CloudSyncCategory) -> Bool {
        switch category {
        case .playHistory: return playHistorySyncEnabled
        case .recap: return recapSyncEnabled
        case .lyricsServer: return lyricsServerSyncEnabled
        case .uiCustomizations: return uiCustomizationsSyncEnabled
        }
    }

    private func canSync(_ category: CloudSyncCategory) -> Bool {
        canSyncBase && isEnabled(category)
    }

    private var canSyncRadioStations: Bool {
        canSyncBase && radioStationsSyncEnabled
    }

    private func refreshRadioStationsIfNeeded() async {
        guard canSyncRadioStations else { return }
        await RadioStationStore.shared.refresh()
    }
    // NWPathMonitor lebt im actor – kein Lifecycle-Problem auf SwiftUI-Structs
    nonisolated(unsafe) private var pathMonitor: NWPathMonitor?
    nonisolated(unsafe) private var uiCustomizationDefaultsObserver: NSObjectProtocol?
    private init() {}

    // MARK: - Visible Sync Status

    private func statusText(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    private func statusText(_ key: String, count: Int) -> String {
        String(format: String(localized: String.LocalizationValue(key)), count)
    }

    private func setCurrentStatus(_ message: String, isSyncing: Bool = true) async {
        currentStatusChangedAt = Date()
        await MainActor.run {
            status.currentMessage = message
            status.isSyncing = isSyncing
        }
    }

    private func finishCurrentStatus(_ message: String? = nil) async {
        await MainActor.run {
            if let message {
                status.currentMessage = message
            }
            status.isSyncing = false
        }
    }

    private func runVisibleStatusStep(
        _ message: String,
        minimumDuration: TimeInterval? = nil,
        operation: () async -> Void
    ) async {
        let startedAt = Date()
        await setCurrentStatus(message)
        operationLog(message)
        await operation()

        let minimumDuration = minimumDuration ?? minimumVisibleStatusDuration
        let visibleSince = max(startedAt.timeIntervalSince1970, currentStatusChangedAt.timeIntervalSince1970)
        let remaining = minimumDuration - (Date().timeIntervalSince1970 - visibleSince)
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    private func operationLog(_ message: String) {
        log(message)
    }

    private func beginSyncWorkflow(named name: String) -> Bool {
        guard !isSyncWorkflowRunning else {
            log("\(name) skipped — another sync is already running")
            return false
        }
        isSyncWorkflowRunning = true
        return true
    }

    private func endSyncWorkflow() {
        isSyncWorkflowRunning = false
        guard isSyncNowQueued else { return }
        isSyncNowQueued = false
        Task { await self.syncNow() }
    }

    // MARK: - Device ID

    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: deviceIdKey) { return id }
        let id = UUID().uuidString.lowercased()
        Self.setUserDefault(.string(id), forKey: deviceIdKey)
        return id
    }

    // MARK: - Change Token

    private func changeToken(for category: CloudSyncCategory) -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: category.tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func setChangeToken(_ token: CKServerChangeToken?, for category: CloudSyncCategory) {
        if let token,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            Self.setUserDefault(.data(data), forKey: category.tokenKey)
        } else {
            Self.removeUserDefault(forKey: category.tokenKey)
        }
    }

    private func clearChangeTokens() {
        for category in CloudSyncCategory.allCases {
            setChangeToken(nil, for: category)
        }
        Self.removeUserDefault(forKey: legacyTokenKey)
    }

    private nonisolated enum UserDefaultValue: Sendable {
        case bool(Bool)
        case string(String)
        case data(Data)
        case stringArray([String])
        case int(Int)
        case double(Double)
    }

    private nonisolated static func setUserDefault(_ value: UserDefaultValue, forKey key: String) {
        if Thread.isMainThread {
            writeUserDefault(value, forKey: key)
        } else {
            DispatchQueue.main.sync {
                writeUserDefault(value, forKey: key)
            }
        }
    }

    private nonisolated static func writeUserDefault(_ value: UserDefaultValue, forKey key: String) {
        switch value {
        case .bool(let value):
            UserDefaults.standard.set(value, forKey: key)
        case .string(let value):
            UserDefaults.standard.set(value, forKey: key)
        case .data(let value):
            UserDefaults.standard.set(value, forKey: key)
        case .stringArray(let value):
            UserDefaults.standard.set(value, forKey: key)
        case .int(let value):
            UserDefaults.standard.set(value, forKey: key)
        case .double(let value):
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private nonisolated static func removeUserDefault(forKey key: String) {
        if Thread.isMainThread {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            DispatchQueue.main.sync {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Setup

    func setup() async {
        debug("[CloudKitSync] setup() starting")
        registerUICustomizationDefaultsObserverIfNeeded()
        guard canSyncBase || canSyncQueue else {
            debug("[CloudKitSync] setup() skipped — sync conditions not met (icloud/offline)")
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

    private func registerUICustomizationDefaultsObserverIfNeeded() {
        if lastUICustomizationSnapshot == nil {
            lastUICustomizationSnapshot = PersonalizationSettings.cloudUICustomizationSnapshot()
        }
        guard uiCustomizationDefaultsObserver == nil else { return }
        uiCustomizationDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in
            Task {
                await CloudKitSyncService.shared.handleUICustomizationDefaultsDidChange()
            }
        }
    }

    private func handleUICustomizationDefaultsDidChange() async {
        guard !isApplyingRemoteUICustomizations else { return }
        let snapshot = PersonalizationSettings.cloudUICustomizationSnapshot()
        guard snapshot != lastUICustomizationSnapshot else { return }

        lastUICustomizationSnapshot = snapshot
        Self.setUserDefault(.double(Date().timeIntervalSince1970), forKey: uiCustomizationsUpdatedAtKey)
        guard canSync(.uiCustomizations) else { return }
        await pushUICustomizationsIfNeeded()
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

    private func refreshAccountAvailability(action: String) async -> Bool {
        let accountStatus = await updateAccountStatus()
        guard accountStatus == .available else {
            log("\(action) skipped — iCloud account not available")
            return false
        }
        return true
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

    @discardableResult
    func uploadPendingEvents() async -> Int {
        guard canSyncBase else {
            logDisabled(.playHistory, action: "pending play upload")
            return 0
        }
        guard canSync(.playHistory) else {
            logDisabled(.playHistory, action: "pending play upload")
            return 0
        }
        guard await status.accountAvailable else {
            debug("[CloudKitSync] uploadPendingEvents skipped – account not available")
            return 0
        }
        let pendingAtStart = await PlayLogService.shared.pendingUploadCount()
        if pendingAtStart > 0 {
            await setCurrentStatus(statusText("sync_status_uploading_plays_format", count: pendingAtStart))
        }
        var totalUploaded = 0
        do {
            try await ensureZoneExists()
            while canSync(.playHistory) {
                let unsynced = await PlayLogService.shared.fetchUnsynced(limit: 200)
                debug("[CloudKitSync] Pending events to upload: \(unsynced.count)")
                guard !unsynced.isEmpty else { return totalUploaded }

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
                guard !records.isEmpty else { return totalUploaded }

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
                totalUploaded += uploaded.count
                await updatePendingCounts()
                debug("[CloudKitSync] Uploaded \(uploaded.count) events (\(failureCount) failures)")
                if failureCount > 0 {
                    log("Uploaded \(uploaded.count) plays (\(failureCount) failed)", isError: true)
                } else {
                    log("Uploaded \(uploaded.count) plays")
                }
                await MainActor.run { status.lastSyncDate = Date() }
                if uploaded.isEmpty { return totalUploaded }
            }
        } catch {
            debug("[CloudKitSync] Upload error: \(error)")
            debug("[CloudKitSync] Upload error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                debug("[CloudKitSync] Upload CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            log("Upload error: \(error.localizedDescription)", isError: true)
        }
        return totalUploaded
    }

    // MARK: - Download

    @discardableResult
    private func downloadChanges() async -> CloudDownloadStats {
        guard canSyncBase else {
            logDisabled(nil, action: "iCloud download")
            return CloudDownloadStats()
        }
        guard await status.accountAvailable else {
            log("Download skipped — iCloud account not available")
            return CloudDownloadStats()
        }
        let enabledCategories = CloudSyncCategory.allCases.filter { canSync($0) }
        guard !enabledCategories.isEmpty else {
            logDisabled(nil, action: "iCloud download")
            return CloudDownloadStats()
        }
        var stats = CloudDownloadStats()
        for category in enabledCategories {
            stats.add(await downloadChanges(for: category))
        }
        return stats
    }

    @discardableResult
    private func downloadChanges(for category: CloudSyncCategory) async -> CloudDownloadStats {
        var stats = CloudDownloadStats()
        do {
            try await ensureZoneExists()
            let token = changeToken(for: category)
            let hasToken = token != nil
            debug("[CloudKitSync] Fetching \(category.displayName) changes with token: \(hasToken ? "hasToken" : "noToken")")
            let (records, deletions, newToken) = try await fetchZoneChanges(previousToken: token)
            debug("[CloudKitSync] Received \(records.count) new records, \(deletions.count) deletions for \(category.displayName)")

            // Deletionen zuerst: verhindert, dass ein Add mit gleichem recordName
            // (z.B. Recap-Marker Reset + Neu-Erzeugung auf anderem Gerät) durch
            // eine nachfolgende Delete-Meldung wieder entfernt wird.
            var playsDel = 0, recapsDel = 0, settingsDel = 0
            for (recordID, recordType) in deletions {
                guard category.handles(recordType: recordType) else { continue }
                switch recordType {
                case "PlayEvent": playsDel += 1
                case "RecapMarker": recapsDel += 1
                case "RecapSettings", "LyricsServerSettings", "UICustomizationSettings": settingsDel += 1
                default: break
                }
                await handleDeletedRecord(id: recordID, type: recordType)
            }
            var playsIn = 0, recapsIn = 0, settingsIn = 0
            for record in records {
                guard category.handles(recordType: record.recordType) else { continue }
                let result = await handleIncomingRecord(record)
                playsIn += result.playsDownloaded
                recapsIn += result.recapsDownloaded
                settingsIn += result.settingsDownloaded
            }
            if playsIn > 0 {
                await setCurrentStatus(statusText("sync_status_downloading_plays_format", count: playsIn))
            } else if recapsIn > 0 {
                await setCurrentStatus(statusText("sync_status_downloading_recaps_format", count: recapsIn))
            }
            stats.playsDownloaded = playsIn
            stats.recapsDownloaded = recapsIn
            stats.settingsDownloaded = settingsIn
            stats.playsDeleted = playsDel
            stats.recapsDeleted = recapsDel
            stats.settingsDeleted = settingsDel
            // Retention-Settings: nach dem Einlesen lokalen Stand ggf. nachschieben.
            if category == .recap {
                await pushRetentionIfNeeded()
            } else if category == .lyricsServer {
                await pushLyricsServerSettingsIfNeeded()
            } else if category == .uiCustomizations {
                await pushUICustomizationsIfNeeded()
            }
            if let token = newToken { setChangeToken(token, for: category) }
            let downloadedSummary = [
                playsIn > 0 ? "\(playsIn) plays" : nil,
                recapsIn > 0 ? "\(recapsIn) recaps" : nil,
                settingsIn > 0 ? "\(settingsIn) settings" : nil
            ].compactMap { $0 }.joined(separator: ", ")
            log("Downloaded \(category.displayName): \(downloadedSummary.isEmpty ? "no changes" : downloadedSummary)")
            if playsDel + recapsDel + settingsDel > 0 {
                let deletedSummary = [
                    playsDel > 0 ? "\(playsDel) plays" : nil,
                    recapsDel > 0 ? "\(recapsDel) recaps" : nil,
                    settingsDel > 0 ? "\(settingsDel) settings" : nil
                ].compactMap { $0 }.joined(separator: ", ")
                log("Deleted on other device (\(category.displayName)): \(deletedSummary)")
            }
            await MainActor.run { status.lastSyncDate = Date() }
        } catch {
            debug("[CloudKitSync] \(category.displayName) download error: \(error)")
            debug("[CloudKitSync] Download error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                debug("[CloudKitSync] Download CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            if isZoneNotFound(error) {
                await markLocalAsUnsyncedForReUpload()
                setChangeToken(nil, for: category)
                isZoneReady = false
                log("iCloud zone was reset on another device — marking local \(category.displayName) data for re-upload")
            } else if isChangeTokenExpired(error) {
                // Zone was wiped and recreated on another device (typical when that device
                // re-enabled sync in the same flow). Treat like zoneNotFound so our local
                // truth gets re-uploaded.
                await markLocalAsUnsyncedForReUpload()
                setChangeToken(nil, for: category)
                isZoneReady = false
                log("Change token expired for \(category.displayName) — marking local data for re-upload")
            } else {
                log("\(category.displayName) download error: \(error.localizedDescription)", isError: true)
            }
        }
        return stats
    }

    private func fetchZoneChanges(previousToken: CKServerChangeToken?) async throws -> (changed: [CKRecord], deleted: [(CKRecord.ID, CKRecord.RecordType)], token: CKServerChangeToken?) {
        try await withCheckedThrowingContinuation { continuation in
            var changed: [CKRecord] = []
            var deleted: [(CKRecord.ID, CKRecord.RecordType)] = []
            var latestToken: CKServerChangeToken?
            var zoneError: Error?

            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = previousToken

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

    private func handleIncomingRecord(_ record: CKRecord) async -> CloudDownloadStats {
        var stats = CloudDownloadStats()
        switch record.recordType {
        case "PlayEvent":
            guard canSync(.playHistory) else { return stats }
            guard
                let uuid       = record["uuid"]         as? String,
                let songId     = record["songId"]        as? String,
                let serverId   = record["serverId"]      as? String,
                let playedAt   = record["playedAt"]      as? Double,
                let duration   = record["songDuration"]  as? Double
            else { return stats }
            if isPlayEventPendingDeletion(uuid) { return stats }
            let changed = await PlayLogService.shared.insertIfNotExists(
                uuid: uuid, songId: songId, serverId: serverId,
                playedAt: playedAt, songDuration: duration
            )
            if changed {
                stats.playsDownloaded = 1
            }

        case "RecapMarker":
            guard canSync(.recap) else { return stats }
            guard
                let playlistId  = record["playlistId"]  as? String,
                let serverId    = record["serverId"]     as? String,
                let periodType  = record["periodType"]   as? String,
                let periodStart = record["periodStart"]  as? Double,
                let periodEnd   = record["periodEnd"]    as? Double
            else { return stats }
            let name = record.recordID.recordName
            // Wiederauferstehungs-Schutz: Marker, der lokal zur Löschung vorgemerkt ist,
            // darf nicht über den Change-Feed wieder eingefügt werden.
            if isMarkerPendingDeletion(name) { return stats }
            if let existing = await PlayLogService.shared.registryEntry(byCKRecordName: name) {
                if existing.playlistId == playlistId {
                    let removed = await PlayLogService.shared.keepOnlyRegistryEntryForSamePeriod(existing)
                    if !removed.isEmpty {
                        debug("[CloudKitSync] Removed \(removed.count) duplicate local recap registry entries for \(name)")
                    }
                    return stats
                }
                // Same ckRecordName, different playlistId → Delete+Recreate-Flow auf anderem Gerät.
                // Alten Eintrag entfernen, neuen übernehmen.
                await PlayLogService.shared.deleteRegistryEntry(playlistId: existing.playlistId)
                stats.recapsDownloaded = 1
            }
            let isTest = (record["isTest"] as? Int64 ?? 0) == 1 || name.hasPrefix("test.")
            let entry = RecapRegistryRecord(
                playlistId: playlistId, serverId: serverId,
                periodType: periodType, periodStart: periodStart, periodEnd: periodEnd,
                ckRecordName: name, isTest: isTest
            )
            let removed = await PlayLogService.shared.keepOnlyRegistryEntryForSamePeriod(entry)
            if !removed.isEmpty {
                debug("[CloudKitSync] Removed \(removed.count) duplicate local recap registry entries for \(name)")
            }
            if stats.recapsDownloaded == 0 {
                stats.recapsDownloaded = 1
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
            }

        case "RecapSettings":
            guard canSync(.recap) else { return stats }
            applyIncomingRetention(record)
            stats.settingsDownloaded = 1

        case "LyricsServerSettings":
            guard canSync(.lyricsServer) else { return stats }
            applyIncomingLyricsServerSettings(record)
            stats.settingsDownloaded = 1

        case "UICustomizationSettings":
            guard canSync(.uiCustomizations) else { return stats }
            applyIncomingUICustomizations(record)
            stats.settingsDownloaded = 1

        default:
            break
        }
        return stats
    }

    private func handleDeletedRecord(id: CKRecord.ID, type: CKRecord.RecordType) async {
        switch type {
        case "RecapMarker":
            guard canSync(.recap) else { return }
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
            guard canSync(.playHistory) else { return }
            await PlayLogService.shared.deletePlayLog(uuid: id.recordName)
            await updatePendingCounts()
        default:
            break
        }
    }

    // MARK: - RecapMarker

    func saveRecapMarker(_ entry: RecapRegistryRecord, periodKey: String) async throws -> RecapMarkerSaveResult {
        guard canSync(.recap) else {
            logDisabled(.recap, action: "recap marker upload")
            return .created
        }
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
        guard canSync(.recap) else {
            logDisabled(.recap, action: "recap marker download")
            return nil
        }
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
        guard canSync(.recap) || force else {
            logDisabled(.recap, action: "recap marker deletion")
            return
        }
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

    // MARK: - Lösch-Wartelisten

    private static let pendingPlayEventDeletionsKey = "shelv_ck_pending_play_event_deletions"

    private var pendingPlayEventDeletions: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.pendingPlayEventDeletionsKey) ?? [] }
        set { Self.setUserDefault(.stringArray(newValue), forKey: Self.pendingPlayEventDeletionsKey) }
    }

    private func isPlayEventPendingDeletion(_ uuid: String) -> Bool {
        pendingPlayEventDeletions.contains(uuid)
    }

    private func clearPendingPlayEventDeletions() {
        Self.removeUserDefault(forKey: Self.pendingPlayEventDeletionsKey)
    }

    private func queuePlayEventDeletions(uuids: [String], force: Bool = false) async {
        let newIds = Set(uuids).subtracting(pendingPlayEventDeletions)
        if !newIds.isEmpty {
            pendingPlayEventDeletions.append(contentsOf: newIds)
        }
        await flushPendingPlayEventDeletions(force: force)
    }

    private func flushPendingPlayEventDeletions(force: Bool = false) async {
        guard canSync(.playHistory) || force else {
            if !pendingPlayEventDeletions.isEmpty {
                logDisabled(.playHistory, action: "queued play event deletion")
            }
            return
        }

        let queue = pendingPlayEventDeletions
        guard !queue.isEmpty else { return }

        for start in stride(from: 0, to: queue.count, by: 400) {
            let names = Array(queue[start..<min(start + 400, queue.count)])
            let ids = names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            do {
                let (_, deleteResults) = try await db.modifyRecords(
                    saving: [],
                    deleting: ids,
                    atomically: false
                )
                var dispositions: [String: PendingDeletionDisposition] = [:]
                for (name, id) in zip(names, ids) {
                    guard let result = deleteResults[id] else {
                        dispositions[name] = .retry
                        log("Play event deletion returned no result — will retry on next sync", isError: true)
                        continue
                    }
                    switch result {
                    case .success:
                        dispositions[name] = .completed
                    case .failure(let error) where Self.isGoneError(error):
                        dispositions[name] = .completed
                    case .failure(let error):
                        dispositions[name] = .retry
                        log("Play event deletion failed — will retry on next sync: \(error.localizedDescription)", isError: true)
                    }
                }
                let completed = RecapSyncLogic.completedDeletionIDs(from: dispositions)
                pendingPlayEventDeletions.removeAll { completed.contains($0) }
            } catch {
                if let ckError = error as? CKError, ckError.code == .zoneNotFound {
                    pendingPlayEventDeletions.removeAll { names.contains($0) }
                } else {
                    log("Play event deletion failed — will retry on next sync: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    // Recap markers use the same persistent retry pattern. Incoming records that
    // are queued for deletion are ignored so a failed CloudKit request cannot
    // resurrect data that was already removed locally.

    private static let pendingMarkerDeletionsKey = "shelv_ck_pending_marker_deletions"

    private var pendingMarkerDeletions: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.pendingMarkerDeletionsKey) ?? [] }
        set { Self.setUserDefault(.stringArray(newValue), forKey: Self.pendingMarkerDeletionsKey) }
    }

    func isMarkerPendingDeletion(_ ckRecordName: String) -> Bool {
        pendingMarkerDeletions.contains(ckRecordName)
    }

    func clearPendingMarkerDeletions() {
        Self.removeUserDefault(forKey: Self.pendingMarkerDeletionsKey)
    }

    /// Marker zur Löschung vormerken und sofort einen Versuch starten.
    func queueRecapMarkerDeletion(ckRecordName: String) async {
        if !pendingMarkerDeletions.contains(ckRecordName) {
            pendingMarkerDeletions.append(ckRecordName)
        }
        await flushPendingMarkerDeletions()
    }

    func flushPendingMarkerDeletions() async {
        guard canSync(.recap) else {
            if !pendingMarkerDeletions.isEmpty {
                logDisabled(.recap, action: "queued marker deletion")
            }
            return
        }
        let queue = pendingMarkerDeletions
        guard !queue.isEmpty else { return }
        for name in queue {
            let rid = CKRecord.ID(recordName: name, zoneID: zoneID)
            do {
                let (_, deleteResults) = try await db.modifyRecords(saving: [], deleting: [rid])
                if case .failure(let err) = deleteResults[rid] ?? .success(()), !Self.isGoneError(err) {
                    log("Marker deletion failed — will retry on next sync: \(err.localizedDescription)", isError: true)
                    continue
                }
                pendingMarkerDeletions.removeAll { $0 == name }
                log("Recap marker deleted (queued)")
            } catch {
                if Self.isGoneError(error) {
                    // Zone/Record existiert nicht mehr — Ziel erreicht.
                    pendingMarkerDeletions.removeAll { $0 == name }
                } else {
                    log("Marker deletion failed — will retry on next sync: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private static func isGoneError(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        return ck.code == .unknownItem || ck.code == .zoneNotFound
    }

    // MARK: - Geteilte Retention-Settings

    /// Von der Settings-UI nach einer Retention-Änderung aufgerufen: lokalen Zeitstempel
    /// setzen und sofort hochzuladen versuchen. Schlägt der Upload fehl (offline/Sync aus),
    /// holt ihn der nächste `syncNow` über `pushRetentionIfNeeded` nach.
    func recordRetentionChange() async {
        Self.setUserDefault(.double(Date().timeIntervalSince1970), forKey: retentionUpdatedAtKey)
        guard canSync(.recap) else {
            logDisabled(.recap, action: "retention upload")
            return
        }
        await pushRetentionIfNeeded()
    }

    /// Lädt den lokalen Retention-Stand hoch, falls er neuer ist als der zuletzt gesyncte.
    func pushRetentionIfNeeded() async {
        guard canSync(.recap) else {
            logDisabled(.recap, action: "retention upload")
            return
        }
        let updatedAt = UserDefaults.standard.double(forKey: retentionUpdatedAtKey)
        let syncedAt  = UserDefaults.standard.double(forKey: retentionSyncedAtKey)
        guard updatedAt > syncedAt else { return }

        let w = retentionValue(Self.weeklyKey, default: 1)
        let m = retentionValue(Self.monthlyKey, default: 12)
        let y = retentionValue(Self.yearlyKey, default: 3)
        do {
            try await ensureZoneExists()
            let rid = CKRecord.ID(recordName: Self.retentionRecordName, zoneID: zoneID)
            let rec = CKRecord(recordType: "RecapSettings", recordID: rid)
            rec["weeklyRetention"]  = Int64(w)
            rec["monthlyRetention"] = Int64(m)
            rec["yearlyRetention"]  = Int64(y)
            rec["updatedAt"]        = updatedAt
            // Singleton, Last-write-wins → Server-Konflikt bewusst überschreiben.
            _ = try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: true)
            Self.setUserDefault(.double(updatedAt), forKey: retentionSyncedAtKey)
            log("Retention settings uploaded")
        } catch {
            log("Retention upload failed — will retry on next sync: \(error.localizedDescription)", isError: true)
        }
    }

    /// Übernimmt einen eingehenden Retention-Record, wenn er neuer ist als der lokale Stand.
    private func applyIncomingRetention(_ record: CKRecord) {
        guard let updatedAt = record["updatedAt"] as? Double else { return }
        let localUpdated = UserDefaults.standard.double(forKey: retentionUpdatedAtKey)
        guard updatedAt > localUpdated else { return }   // lokaler Wert ist neuer → behalten
        if let w = record["weeklyRetention"]  as? Int64 { Self.setUserDefault(.int(Int(w)), forKey: Self.weeklyKey) }
        if let m = record["monthlyRetention"] as? Int64 { Self.setUserDefault(.int(Int(m)), forKey: Self.monthlyKey) }
        if let y = record["yearlyRetention"]  as? Int64 { Self.setUserDefault(.int(Int(y)), forKey: Self.yearlyKey) }
        Self.setUserDefault(.double(updatedAt), forKey: retentionUpdatedAtKey)
        Self.setUserDefault(.double(updatedAt), forKey: retentionSyncedAtKey)   // kommt vom Server → kein Re-Upload
        log("Retention settings updated from iCloud")
    }

    private func retentionValue(_ key: String, default def: Int) -> Int {
        let raw = UserDefaults.standard.integer(forKey: key)
        return raw > 0 ? raw : def
    }

    // MARK: - Geteilte Lyrics-Server-Settings

    func recordLyricsServerSettingsChange() async {
        if shouldSuppressLyricsServerEcho() {
            log("Lyrics server settings echo skipped")
            return
        }
        clearLyricsServerEchoMarker()
        Self.setUserDefault(.double(Date().timeIntervalSince1970), forKey: lyricsServerUpdatedAtKey)
        guard canSync(.lyricsServer) else {
            logDisabled(.lyricsServer, action: "lyrics server settings upload")
            return
        }
        await pushLyricsServerSettingsIfNeeded()
    }

    func pushLyricsServerSettingsIfNeeded() async {
        guard canSync(.lyricsServer) else {
            logDisabled(.lyricsServer, action: "lyrics server settings upload")
            return
        }
        var updatedAt = UserDefaults.standard.double(forKey: lyricsServerUpdatedAtKey)
        let syncedAt = UserDefaults.standard.double(forKey: lyricsServerSyncedAtKey)
        let useCustom = UserDefaults.standard.bool(forKey: Self.lyricsUseCustomKey)
        let customURL = UserDefaults.standard.string(forKey: Self.lyricsCustomURLKey) ?? ""
        let onlineFallback = LrcLibEndpoint.isOnlineFallbackEnabled

        if updatedAt == 0, useCustom || !customURL.isEmpty || !onlineFallback {
            updatedAt = Date().timeIntervalSince1970
            Self.setUserDefault(.double(updatedAt), forKey: lyricsServerUpdatedAtKey)
        }
        guard updatedAt > syncedAt else { return }

        do {
            try await ensureZoneExists()
            let rid = CKRecord.ID(recordName: Self.lyricsServerRecordName, zoneID: zoneID)
            let rec = CKRecord(recordType: "LyricsServerSettings", recordID: rid)
            rec["useCustom"] = useCustom ? 1 : 0
            rec["customBaseURL"] = customURL
            rec["onlineFallbackEnabled"] = onlineFallback ? 1 : 0
            rec["updatedAt"] = updatedAt
            _ = try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: true)
            Self.setUserDefault(.double(updatedAt), forKey: lyricsServerSyncedAtKey)
            log("Lyrics server settings uploaded")
        } catch {
            log("Lyrics server settings upload failed — will retry on next sync: \(error.localizedDescription)", isError: true)
        }
    }

    private func applyIncomingLyricsServerSettings(_ record: CKRecord) {
        guard let updatedAt = record["updatedAt"] as? Double else { return }
        let localUpdated = UserDefaults.standard.double(forKey: lyricsServerUpdatedAtKey)
        guard updatedAt > localUpdated else { return }
        let useCustom = (record["useCustom"] as? Int64 ?? 0) == 1
        let customURL = record["customBaseURL"] as? String ?? ""
        let onlineFallback = (record["onlineFallbackEnabled"] as? Int64).map { $0 == 1 } ?? true
        Self.setUserDefault(.bool(useCustom), forKey: Self.lyricsUseCustomKey)
        Self.setUserDefault(.string(customURL), forKey: Self.lyricsCustomURLKey)
        Self.setUserDefault(.bool(onlineFallback), forKey: Self.lyricsOnlineFallbackKey)
        Self.setUserDefault(.double(updatedAt), forKey: lyricsServerUpdatedAtKey)
        Self.setUserDefault(.double(updatedAt), forKey: lyricsServerSyncedAtKey)
        Self.setUserDefault(.bool(useCustom), forKey: lyricsServerEchoUseCustomKey)
        Self.setUserDefault(.string(customURL), forKey: lyricsServerEchoCustomURLKey)
        Self.setUserDefault(.bool(onlineFallback), forKey: lyricsServerEchoOnlineFallbackKey)
        Self.setUserDefault(.double(updatedAt), forKey: lyricsServerEchoUpdatedAtKey)
        log("Lyrics server settings updated from iCloud")
    }

    private func shouldSuppressLyricsServerEcho() -> Bool {
        let echoUpdatedAt = UserDefaults.standard.double(forKey: lyricsServerEchoUpdatedAtKey)
        guard echoUpdatedAt > 0 else { return false }
        guard UserDefaults.standard.double(forKey: lyricsServerUpdatedAtKey) == echoUpdatedAt else { return false }
        guard UserDefaults.standard.double(forKey: lyricsServerSyncedAtKey) == echoUpdatedAt else { return false }

        let useCustom = UserDefaults.standard.bool(forKey: Self.lyricsUseCustomKey)
        let customURL = UserDefaults.standard.string(forKey: Self.lyricsCustomURLKey) ?? ""
        let onlineFallback = LrcLibEndpoint.isOnlineFallbackEnabled
        let echoUseCustom = UserDefaults.standard.bool(forKey: lyricsServerEchoUseCustomKey)
        let echoCustomURL = UserDefaults.standard.string(forKey: lyricsServerEchoCustomURLKey) ?? ""
        let echoOnlineFallback = UserDefaults.standard.bool(forKey: lyricsServerEchoOnlineFallbackKey)
        return useCustom == echoUseCustom && customURL == echoCustomURL && onlineFallback == echoOnlineFallback
    }

    private func clearLyricsServerEchoMarker() {
        Self.removeUserDefault(forKey: lyricsServerEchoUseCustomKey)
        Self.removeUserDefault(forKey: lyricsServerEchoCustomURLKey)
        Self.removeUserDefault(forKey: lyricsServerEchoOnlineFallbackKey)
        Self.removeUserDefault(forKey: lyricsServerEchoUpdatedAtKey)
    }

    // MARK: - Geteilte UI-Customization-Settings

    func pushUICustomizationsIfNeeded() async {
        guard canSync(.uiCustomizations) else {
            logDisabled(.uiCustomizations, action: "UI customizations upload")
            return
        }

        var updatedAt = UserDefaults.standard.double(forKey: uiCustomizationsUpdatedAtKey)
        let syncedAt = UserDefaults.standard.double(forKey: uiCustomizationsSyncedAtKey)
        let snapshot = PersonalizationSettings.cloudUICustomizationSnapshot()
        lastUICustomizationSnapshot = snapshot

        if updatedAt == 0, PersonalizationSettings.hasCustomizedCloudUICustomizationValues() {
            updatedAt = Date().timeIntervalSince1970
            Self.setUserDefault(.double(updatedAt), forKey: uiCustomizationsUpdatedAtKey)
        }

        guard updatedAt > syncedAt else { return }
        guard let payload = encodedUICustomizationPayload(values: snapshot) else {
            log("UI customizations upload failed — could not encode settings", isError: true)
            return
        }

        do {
            try await ensureZoneExists()
            let rid = CKRecord.ID(recordName: Self.uiCustomizationsRecordName, zoneID: zoneID)
            let rec = CKRecord(recordType: "UICustomizationSettings", recordID: rid)
            rec["payload"] = payload as CKRecordValue
            rec["updatedAt"] = updatedAt
            rec["deviceId"] = deviceId
            _ = try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: true)
            Self.setUserDefault(.double(updatedAt), forKey: uiCustomizationsSyncedAtKey)
            log("UI customizations uploaded")
        } catch {
            log("UI customizations upload failed — will retry on next sync: \(error.localizedDescription)", isError: true)
        }
    }

    private func applyIncomingUICustomizations(_ record: CKRecord) {
        guard let updatedAt = record["updatedAt"] as? Double else { return }
        let localUpdated = UserDefaults.standard.double(forKey: uiCustomizationsUpdatedAtKey)
        guard updatedAt > localUpdated else { return }

        guard
            let payloadData = record["payload"] as? Data,
            let payload = decodedUICustomizationPayload(from: payloadData)
        else { return }

        isApplyingRemoteUICustomizations = true
        defer { isApplyingRemoteUICustomizations = false }

        PersonalizationSettings.applyCloudUICustomizationSnapshot(payload.values)
        lastUICustomizationSnapshot = PersonalizationSettings.cloudUICustomizationSnapshot()
        Self.setUserDefault(.double(updatedAt), forKey: uiCustomizationsUpdatedAtKey)
        Self.setUserDefault(.double(updatedAt), forKey: uiCustomizationsSyncedAtKey)
        log("UI customizations updated from iCloud")
    }

    private func encodedUICustomizationPayload(values: [String: PersonalizationCloudValue]) -> Data? {
        let payload = CloudUICustomizationPayload(schemaVersion: 1, values: values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    private func decodedUICustomizationPayload(from data: Data) -> CloudUICustomizationPayload? {
        try? JSONDecoder().decode(CloudUICustomizationPayload.self, from: data)
    }

    func deletePlayEvent(uuid: String, force: Bool = false) async {
        await queuePlayEventDeletions(uuids: [uuid], force: force)
    }

    func deletePlayEvents(uuids: [String], force: Bool = false) async {
        guard !uuids.isEmpty else { return }
        await queuePlayEventDeletions(uuids: uuids, force: force)
    }

    func deleteZone(force: Bool = false) async {
        guard syncEnabled || force else { return }
        await MainActor.run { status.isSyncing = true }
        log("Deleting iCloud zone…")
        do {
            _ = try await db.deleteRecordZone(withID: zoneID)
            isZoneReady = false
            clearChangeTokens()
            clearPendingPlayEventDeletions()
            clearPendingMarkerDeletions()   // Zone weg = wartende Marker-Löschungen erledigt
            await markLocalAsUnsyncedForReUpload()
            await MainActor.run {
                status.lastSyncDate = Date()
                status.isSyncing = false
            }
            log("iCloud zone deleted")
        } catch {
            await MainActor.run { status.isSyncing = false }
            if let ck = error as? CKError, ck.code == .zoneNotFound {
                isZoneReady = false
                clearChangeTokens()
                clearPendingPlayEventDeletions()
                clearPendingMarkerDeletions()
                await markLocalAsUnsyncedForReUpload()
                log("iCloud zone already gone")
            } else {
                log("Zone deletion failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func markLocalAsUnsyncedForReUpload() async {
        // Settings sind serverunabhängig: nach einem Zone-Wipe den lokalen Stand neu
        // hochladbar machen, damit er nicht aus iCloud verschwindet.
        if UserDefaults.standard.double(forKey: retentionUpdatedAtKey) > 0 {
            Self.setUserDefault(.double(0), forKey: retentionSyncedAtKey)
        }
        let lyricsUpdatedAt = UserDefaults.standard.double(forKey: lyricsServerUpdatedAtKey)
        let useCustomLyricsServer = UserDefaults.standard.bool(forKey: Self.lyricsUseCustomKey)
        let customLyricsURL = UserDefaults.standard.string(forKey: Self.lyricsCustomURLKey) ?? ""
        let onlineFallback = LrcLibEndpoint.isOnlineFallbackEnabled
        if lyricsUpdatedAt > 0 || useCustomLyricsServer || !customLyricsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !onlineFallback {
            Self.setUserDefault(.double(0), forKey: lyricsServerSyncedAtKey)
        }
        if UserDefaults.standard.double(forKey: uiCustomizationsUpdatedAtKey) > 0
            || PersonalizationSettings.hasCustomizedCloudUICustomizationValues() {
            Self.setUserDefault(.double(0), forKey: uiCustomizationsSyncedAtKey)
        }
        await PlayLogService.shared.markAllUnsyncedForReUpload()
        await updatePendingCounts()
    }

    func deleteRecapMarkers(serverId: String, force: Bool = false) async {
        guard canSync(.recap) || force else {
            logDisabled(.recap, action: "recap marker deletion")
            return
        }
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

    // MARK: - PlayQueue (geräteübergreifende Wiedergabe-Queue)

    // Eigenes Gate, bewusst unabhängig vom Recap-/PlayLog-Sync (`syncEnabled`).
    // CloudKit wird hier nur verwendet, wenn Queue-Sync explizit auf iCloud steht.
    private var canSyncQueue: Bool {
        UserDefaults.standard.string(forKey: queueSyncModeKey) == QueueSyncMode.icloud.rawValue
            && !offlineModeEnabled
    }

    // Ein gemeinsamer Record pro Server (last-write-wins). recordName serverScoped.
    private func playQueueRecordID(serverId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "playqueue.\(serverId.lowercased())", zoneID: zoneID)
    }

    /// Lädt den (vom Aufrufer JSON-codierten) Queue-Snapshot in einen einzelnen Record.
    /// Codable-Arbeit bleibt bewusst beim @MainActor-Aufrufer (QueueSyncService) — der
    /// Actor hantiert nur mit `Data`, um main-actor-isolierte Conformances zu vermeiden.
    /// Liefert `true` nur bei bestätigtem Upload — der Aufrufer merkt sich die Signatur sonst nicht.
    @discardableResult
    func savePlayQueue(serverId: String, payload: Data, changedAt: Double, signature: String) async -> Bool {
        guard canSyncQueue else { return false }
        guard await status.accountAvailable else { return false }
        do {
            try await ensureZoneExists()
            let record = CKRecord(recordType: "PlayQueue", recordID: playQueueRecordID(serverId: serverId))
            record["serverId"]  = serverId
            record["payload"]   = payload as CKRecordValue
            record["changedAt"] = changedAt
            record["signature"] = signature
            // Singleton pro Server, last-write-wins → Server-Konflikt bewusst überschreiben.
            _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
            debug("[CloudKitSync] PlayQueue uploaded (\(payload.count) bytes)")
            return true
        } catch {
            debug("[CloudKitSync] PlayQueue save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Liest den rohen Queue-Payload für einen Server. `nil`, wenn keiner existiert.
    func fetchPlayQueuePayload(serverId: String) async -> Data? {
        guard canSyncQueue else { return nil }
        guard await status.accountAvailable else { return nil }
        do {
            try await ensureZoneExists()
            let record = try await db.record(for: playQueueRecordID(serverId: serverId))
            return record["payload"] as? Data
        } catch {
            // unknownItem = kein Record vorhanden → kein Fehler, einfach nil.
            return nil
        }
    }

    // MARK: - Radio Metadata

    private func radioMetadataRecordID(recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    func fetchRadioMetadata(recordNames: [String]) async -> [RadioStationMetadata] {
        guard canSyncRadioStations else { return [] }
        guard await status.accountAvailable else { return [] }
        guard !recordNames.isEmpty else { return [] }

        do {
            try await ensureZoneExists()
        } catch {
            debug("[CloudKitSync] Radio metadata fetch setup failed: \(error.localizedDescription)")
            return []
        }

        var result: [RadioStationMetadata] = []
        for name in Set(recordNames) {
            do {
                let record = try await db.record(for: radioMetadataRecordID(recordName: name))
                if let metadata = Self.radioMetadata(from: record) {
                    result.append(metadata)
                }
            } catch {
                continue
            }
        }
        return result
    }

    func saveRadioMetadata(_ metadata: RadioStationMetadata) async {
        guard canSyncRadioStations else { return }
        guard await status.accountAvailable else { return }
        do {
            try await ensureZoneExists()
            let record = CKRecord(recordType: "RadioStationMetadata", recordID: radioMetadataRecordID(recordName: metadata.recordName))
            record["serverId"] = metadata.serverId
            record["stationId"] = metadata.stationId
            record["streamURLKey"] = metadata.streamURLKey
            record["useAzuraCastAPI"] = metadata.useAzuraCastAPI ? 1 : 0
            record["azuraCastAPIURL"] = metadata.azuraCastAPIURL
            record["showSongCover"] = metadata.showSongCover ? 1 : 0
            record["updatedAt"] = metadata.updatedAt
            _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
            debug("[CloudKitSync] Radio metadata uploaded")
        } catch {
            debug("[CloudKitSync] Radio metadata upload failed: \(error.localizedDescription)")
        }
    }

    func deleteRadioMetadata(recordName: String) async {
        guard canSyncRadioStations else { return }
        guard await status.accountAvailable else { return }
        do {
            try await ensureZoneExists()
            _ = try await db.deleteRecord(withID: radioMetadataRecordID(recordName: recordName))
            debug("[CloudKitSync] Radio metadata deleted")
        } catch {
            if !Self.isGoneError(error) {
                debug("[CloudKitSync] Radio metadata deletion failed: \(error.localizedDescription)")
            }
        }
    }

    private static func radioMetadata(from record: CKRecord) -> RadioStationMetadata? {
        guard record.recordType == "RadioStationMetadata",
              let serverId = record["serverId"] as? String,
              let stationId = record["stationId"] as? String,
              let streamURLKey = record["streamURLKey"] as? String
        else { return nil }
        return RadioStationMetadata(
            recordName: record.recordID.recordName,
            serverId: serverId,
            stationId: stationId,
            streamURLKey: streamURLKey,
            useAzuraCastAPI: (record["useAzuraCastAPI"] as? Int64 ?? 0) == 1,
            azuraCastAPIURL: record["azuraCastAPIURL"] as? String ?? "",
            showSongCover: (record["showSongCover"] as? Int64 ?? 1) == 1,
            updatedAt: record["updatedAt"] as? Double ?? 0
        )
    }

    // MARK: - Scrobble Queue

    func flushScrobbleQueue() async {
        await ScrobbleService.shared.flushPendingScrobbles()
        await updatePendingCounts()
    }

    func syncNow() async {
        guard beginSyncWorkflow(named: "Sync") else {
            isSyncNowQueued = true
            log("Sync queued — another sync is already running")
            return
        }
        defer { endSyncWorkflow() }
        recapSyncFailureMessage = nil

        // Queue-Sync hängt an einem eigenen Toggle und läuft unabhängig vom Play-Log-Sync.
        // Bei jedem Sync-Auslöser (Foreground, Pull-to-Refresh, Mac-Refresh, Netz-Reconnect)
        // die Remote-Queue mitprüfen — so wird ein fremder Stand zuverlässig überall erkannt.
        Task { @MainActor in await QueueSyncService.shared.checkForRemoteQueue() }
        // Navidrome-Outbox ist ausdrücklich unabhängig von den folgenden iCloud-Gates.
        await flushScrobbleQueue()
        guard canSyncBase else {
            logDisabled(nil, action: "iCloud sync")
            return
        }
        guard canSync else {
            logDisabled(nil, action: "iCloud sync")
            return
        }
        guard await refreshAccountAvailability(action: "iCloud sync") else { return }
        log("Syncing…")
        await flushPendingPlayEventDeletions()
        if canSync(.recap) {
            await flushPendingMarkerDeletions()
        } else {
            logDisabled(.recap, action: "queued marker deletion")
        }
        let pendingUploads = await PlayLogService.shared.pendingUploadCount()
        if pendingUploads > 0 {
            await runVisibleStatusStep(statusText("sync_status_uploading_plays_format", count: pendingUploads)) {
                _ = await uploadPendingEvents()
            }
        }
        await runVisibleStatusStep(statusText("sync_status_checking_icloud")) {
            _ = await downloadChanges()
        }
        let remainingUploads = await PlayLogService.shared.pendingUploadCount()
        if remainingUploads > 0 {
            await runVisibleStatusStep(statusText("sync_status_uploading_plays_format", count: remainingUploads)) {
                _ = await uploadPendingEvents()
            }
        }
        if canSync(.recap) {
            await runVisibleStatusStep(statusText("sync_status_syncing_recaps")) {
                await reuploadAllRecapMarkers()
                let activeServerId = await MainActor.run { SubsonicAPIService.shared.activeServer?.stableId } ?? ""
                if !activeServerId.isEmpty {
                    await canonicalizeLocalRecapRegistry(serverId: activeServerId)
                    let updated = await applyRecapDiffsWithNavidrome(serverId: activeServerId)
                    if updated > 0 {
                        await setCurrentStatus(statusText("sync_status_updating_recap_playlists_format", count: updated))
                    }
                    _ = await cleanupShelvRecapPlaylistsOnServer(serverId: activeServerId)
                }
            }
        } else {
            logDisabled(.recap, action: "recap marker reupload")
        }
        await pushLyricsServerSettingsIfNeeded()
        await pushUICustomizationsIfNeeded()
        await refreshRadioStationsIfNeeded()
        await finishCurrentStatus(recapSyncFailureMessage ?? statusText("sync_status_complete"))
        log("Sync done")
    }

    // MARK: - flushAndWait (mit Timeout)

    func flushAndWait(timeout: TimeInterval = 60) async throws {
        guard await refreshAccountAvailability(action: "iCloud flush") else { return }
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
        clearChangeTokens()
        isZoneReady = false
    }

    private func resetChangeToken(for category: CloudSyncCategory) {
        setChangeToken(nil, for: category)
        isZoneReady = false
    }

    func handleSyncEnabledChange() async {
        guard syncEnabled else {
            await finishCurrentStatus(statusText("sync_status_idle"))
            log("iCloud sync disabled")
            return
        }
        await runInitialICloudReconcile()
    }

    private func runInitialICloudReconcile() async {
        guard beginSyncWorkflow(named: "Initial iCloud sync") else { return }
        defer { endSyncWorkflow() }
        recapSyncFailureMessage = nil

        log("iCloud sync enabled — merging local and iCloud data")
        guard await refreshAccountAvailability(action: "Initial iCloud sync") else {
            await finishCurrentStatus(statusText("sync_status_idle"))
            return
        }

        let activeServerId = await MainActor.run { SubsonicAPIService.shared.activeServer?.stableId } ?? ""

        await runVisibleStatusStep(statusText("sync_status_preparing_icloud")) {
            await setup()
            let assigned = await PlayLogService.shared.assignMissingCloudIdentifiers()
            if assigned > 0 {
                self.log("Prepared \(assigned) local plays for iCloud upload")
            }
            resetChangeToken(for: .playHistory)
            resetChangeToken(for: .recap)
            resetChangeToken(for: .uiCustomizations)
        }

        if canSync(.playHistory) {
            await flushPendingPlayEventDeletions()
            await runVisibleStatusStep(statusText("sync_status_checking_icloud")) {
                _ = await downloadChanges(for: .playHistory)
            }

            let pendingUploads = await PlayLogService.shared.pendingUploadCount()
            if pendingUploads > 0 {
                await runVisibleStatusStep(statusText("sync_status_uploading_plays_format", count: pendingUploads)) {
                    _ = await uploadPendingEvents()
                }
            }

            await runVisibleStatusStep(statusText("sync_status_merging_play_history")) {
                _ = await downloadChanges(for: .playHistory)
                _ = await uploadPendingEvents()
            }

            if !activeServerId.isEmpty {
                await runVisibleStatusStep(statusText("sync_status_cleaning_play_database")) {
                    let result = await cleanupDeadPlayLogEntries(serverId: activeServerId)
                    if result.removedRows > 0 {
                        self.log("Removed \(result.removedRows) dead play rows")
                    }
                }
            }
        } else {
            logDisabled(.playHistory, action: "initial play history reconcile")
        }

        if canSync(.recap), !activeServerId.isEmpty {
            await runVisibleStatusStep(statusText("sync_status_downloading_recaps")) {
                _ = await downloadChanges(for: .recap)
            }

            await runVisibleStatusStep(statusText("sync_status_uploading_recaps")) {
                await reuploadAllRecapMarkers()
            }

            await runVisibleStatusStep(statusText("sync_status_resolving_recap_conflicts")) {
                await canonicalizeLocalRecapRegistry(serverId: activeServerId)
            }

            await runVisibleStatusStep(statusText("sync_status_updating_recap_playlists")) {
                let updated = await applyRecapDiffsWithNavidrome(serverId: activeServerId)
                if updated > 0 {
                    await setCurrentStatus(statusText("sync_status_updating_recap_playlists_format", count: updated))
                }
            }

            await runVisibleStatusStep(statusText("sync_status_cleaning_duplicate_recaps")) {
                let deleted = await cleanupShelvRecapPlaylistsOnServer(serverId: activeServerId)
                if deleted > 0 {
                    self.log("Deleted \(deleted) duplicate ShelV recap playlists")
                }
            }
        } else {
            logDisabled(.recap, action: "initial recap reconcile")
        }

        await runVisibleStatusStep(statusText("sync_status_verifying_icloud")) {
            resetChangeToken(for: .playHistory)
            resetChangeToken(for: .recap)
            resetChangeToken(for: .uiCustomizations)
            _ = await downloadChanges()
            _ = await uploadPendingEvents()
            if canSync(.recap), !activeServerId.isEmpty {
                recapSyncFailureMessage = nil
                await reuploadAllRecapMarkers()
                await canonicalizeLocalRecapRegistry(serverId: activeServerId)
                _ = await applyRecapDiffsWithNavidrome(serverId: activeServerId)
                _ = await cleanupShelvRecapPlaylistsOnServer(serverId: activeServerId)
            }
            await pushLyricsServerSettingsIfNeeded()
            await pushUICustomizationsIfNeeded()
            await flushScrobbleQueue()
            await updatePendingCounts()
        }

        await finishCurrentStatus(recapSyncFailureMessage ?? statusText("sync_status_complete"))
        await MainActor.run { status.lastSyncDate = Date() }
        log("Initial iCloud sync complete")
    }

    private func cleanupDeadPlayLogEntries(serverId: String) async -> (checkedSongs: Int, removedRows: Int, deletedCloudEvents: Int) {
        let ids = await PlayLogService.shared.distinctSongIds(serverId: serverId)
        guard !ids.isEmpty else { return (0, 0, 0) }

        var dead: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = ids.makeIterator()
            let maxConcurrent = 6
            var inFlight = 0

            while inFlight < maxConcurrent, let id = iterator.next() {
                inFlight += 1
                group.addTask { (id, await Self.songIsDead(id: id)) }
            }

            for await (id, isDead) in group {
                if isDead { dead.append(id) }
                if let next = iterator.next() {
                    group.addTask { (next, await Self.songIsDead(id: next)) }
                }
            }
        }

        guard !dead.isEmpty else { return (ids.count, 0, 0) }

        let cleanup = await removeDeadPlayLogEntries(songIds: dead, serverId: serverId)
        return (ids.count, cleanup.removedRows, cleanup.deletedCloudEvents)
    }

    func removeDeadPlayLogEntries(
        songIds: [String],
        serverId: String
    ) async -> (removedRows: Int, deletedCloudEvents: Int) {
        let idsToDelete = Array(Set(songIds))
        guard !idsToDelete.isEmpty else { return (0, 0) }

        let uuids = await PlayLogService.shared.uuids(forSongIds: idsToDelete, serverId: serverId)
        if !uuids.isEmpty {
            await deletePlayEvents(uuids: uuids, force: true)
        }
        let removed = await PlayLogService.shared.deletePlays(
            forSongIds: idsToDelete,
            serverId: serverId
        )
        if removed > 0 {
            log("Removed \(removed) play rows for \(idsToDelete.count) missing Navidrome song ID(s)")
        }
        return (removed, uuids.count)
    }

    private nonisolated static func songIsDead(id: String) async -> Bool {
        do {
            _ = try await SubsonicAPIService.shared.getSong(id: id)
            return false
        } catch SubsonicAPIError.apiError(let code, let message) {
            return RecapSyncLogic.isDefinitiveNotFound(code: code, message: message)
        } catch {
            return false
        }
    }

    private func canonicalizeLocalRecapRegistry(serverId: String) async {
        let entries = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        let grouped = Dictionary(grouping: entries) { entry in
            "\(entry.serverId)|\(entry.periodType)|\(entry.periodStart)|\(entry.isTest)"
        }

        for (_, group) in grouped where group.count > 1 {
            let canonical = group.first(where: { $0.ckRecordName != nil }) ?? group[0]
            let removed = await PlayLogService.shared.keepOnlyRegistryEntryForSamePeriod(canonical)
            if !removed.isEmpty {
                debug("[CloudKitSync] Canonicalized recap period, kept \(canonical.playlistId), removed \(removed.count)")
            }
        }

        await RecapStore.shared.loadEntries(serverId: serverId)
    }

    private func applyRecapDiffsWithNavidrome(serverId: String) async -> Int {
        let diffs: [RecapDiff]
        do {
            diffs = try await RecapStore.shared.computeDiffs(serverId: serverId)
        } catch {
            if recapSyncFailureMessage == nil {
                recapSyncFailureMessage = error.localizedDescription
            }
            log("Recap playlist inspection failed: \(error.localizedDescription)", isError: true)
            return 0
        }
        guard !diffs.isEmpty else { return 0 }

        var applied = 0
        for diff in diffs {
            let decision: RecapDiffDecision = diff.serverMissing ? .createNew : .update
            do {
                try await RecapStore.shared.applyDiff(diff, decision: decision, serverId: serverId)
                applied += 1
            } catch {
                if recapSyncFailureMessage == nil {
                    recapSyncFailureMessage = error.localizedDescription
                }
                log("Recap playlist update failed: \(error.localizedDescription)", isError: true)
            }
        }
        await RecapStore.shared.loadEntries(serverId: serverId)
        return applied
    }

    private func cleanupShelvRecapPlaylistsOnServer(serverId: String) async -> Int {
        let canonicalIds = Set(await PlayLogService.shared.allRegistryEntries(serverId: serverId).map(\.playlistId))
        guard !canonicalIds.isEmpty else { return 0 }

        let playlists: [Playlist]
        do {
            playlists = try await SubsonicAPIService.shared.getPlaylists()
        } catch {
            log("Recap server cleanup skipped: \(error.localizedDescription)", isError: true)
            return 0
        }

        let obsolete = playlists.filter { playlist in
            (playlist.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "Shelv Recap"
                && !canonicalIds.contains(playlist.id)
        }

        var deleted = 0
        for playlist in obsolete {
            do {
                try await SubsonicAPIService.shared.deletePlaylist(id: playlist.id)
                deleted += 1
            } catch SubsonicAPIError.apiError(let code, let message)
                where code == 70 || (message ?? "").localizedCaseInsensitiveContains("not found") {
                deleted += 1
            } catch {
                log("Could not delete duplicate recap playlist \(playlist.id): \(error.localizedDescription)", isError: true)
            }
        }
        return deleted
    }

    func handleSyncCategoryChange() async {
        guard beginSyncWorkflow(named: "What to Sync update") else { return }
        defer { endSyncWorkflow() }
        recapSyncFailureMessage = nil

        log("What to Sync updated — Play History: \(playHistorySyncEnabled ? "on" : "off"), Recap: \(recapSyncEnabled ? "on" : "off"), Lyrics Server: \(lyricsServerSyncEnabled ? "on" : "off"), Radio Stations: \(radioStationsSyncEnabled ? "on" : "off"), UI Customizations: \(uiCustomizationsSyncEnabled ? "on" : "off")")
        guard canSyncBase else {
            logDisabled(nil, action: "What to Sync update")
            return
        }
        guard await refreshAccountAvailability(action: "What to Sync update") else { return }
        if canSync(.playHistory) {
            await flushPendingPlayEventDeletions()
            let pendingUploads = await PlayLogService.shared.pendingUploadCount()
            if pendingUploads > 0 {
                await runVisibleStatusStep(statusText("sync_status_uploading_plays_format", count: pendingUploads)) {
                    _ = await uploadPendingEvents()
                }
            }
        }
        await runVisibleStatusStep(statusText("sync_status_checking_icloud")) {
            _ = await downloadChanges()
        }
        if canSync(.recap) {
            await runVisibleStatusStep(statusText("sync_status_syncing_recaps")) {
                await pushRetentionIfNeeded()
                await reuploadAllRecapMarkers()
                let activeServerId = await MainActor.run { SubsonicAPIService.shared.activeServer?.stableId } ?? ""
                if !activeServerId.isEmpty {
                    await canonicalizeLocalRecapRegistry(serverId: activeServerId)
                    let updated = await applyRecapDiffsWithNavidrome(serverId: activeServerId)
                    if updated > 0 {
                        await setCurrentStatus(statusText("sync_status_updating_recap_playlists_format", count: updated))
                    }
                    _ = await cleanupShelvRecapPlaylistsOnServer(serverId: activeServerId)
                }
            }
        }
        if canSync(.lyricsServer) {
            await pushLyricsServerSettingsIfNeeded()
        }
        await refreshRadioStationsIfNeeded()
        if canSync(.uiCustomizations) {
            await pushUICustomizationsIfNeeded()
        }
        await updatePendingCounts()
        await finishCurrentStatus(recapSyncFailureMessage ?? statusText("sync_status_complete"))
    }

    private func reuploadAllRecapMarkers() async {
        guard canSync(.recap) else {
            logDisabled(.recap, action: "recap marker reupload")
            return
        }
        await reuploadRecapMarkers(onlyLocalOnly: false)
    }

    private func reuploadRecapMarkers(onlyLocalOnly: Bool) async {
        let stableId = await MainActor.run { SubsonicAPIService.shared.activeServer?.stableId } ?? ""
        guard !stableId.isEmpty else { return }
        let all = await PlayLogService.shared.allRegistryEntries(serverId: stableId)
        let entries = onlyLocalOnly ? all.filter { $0.ckRecordName == nil } : all
        guard !entries.isEmpty else { return }
        await setCurrentStatus(
            onlyLocalOnly
                ? statusText("sync_status_uploading_recaps_format", count: entries.count)
                : statusText("sync_status_syncing_recaps")
        )
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

            do {
                _ = try await SubsonicAPIService.shared.getPlaylist(id: conflict.existingPlaylistId)
                if onlyLocalOnly {
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
                    await PlayLogService.shared.keepOnlyRegistryEntryForSamePeriod(updated)
                }
            } catch SubsonicAPIError.apiError(let code, let message)
                where RecapSyncLogic.isDefinitiveNotFound(code: code, message: message) {
                let scope = onlyLocalOnly ? "" : " (full)"
                CloudKitSyncService.debugLog("[Reupload] conflict\(scope): iCloud playlistId=\(conflict.existingPlaylistId) MISSING on Navidrome — keeping local \(conflict.entry.playlistId), clearing stale iCloud marker")
                await deleteRecapMarker(ckRecordName: recordName)
                var entry = conflict.entry
                entry.ckRecordName = nil
                _ = try? await saveRecapMarker(entry, periodKey: conflict.periodKey)
            } catch {
                if recapSyncFailureMessage == nil {
                    recapSyncFailureMessage = error.localizedDescription
                }
                log("Could not resolve recap marker conflict: \(error.localizedDescription)", isError: true)
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

    private func logDisabled(_ category: CloudSyncCategory?, action: String) {
        let key = "\(category?.rawValue ?? "all").\(action)"
        let now = Date()
        let message: String
        if !syncEnabled {
            message = "iCloud sync disabled — \(action) skipped"
        } else if offlineModeEnabled {
            message = "Offline mode active — \(action) skipped"
        } else if let category {
            message = "\(category.displayName) sync disabled — \(action) skipped"
        } else {
            message = "iCloud sync categories disabled — \(action) skipped"
        }
        if let last = lastDisabledLogAt[key], now.timeIntervalSince(last) < 30 {
            debug("[CloudKitSync] \(message)")
            return
        }
        lastDisabledLogAt[key] = now
        log(message)
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
