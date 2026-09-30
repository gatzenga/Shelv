import CloudKit
import Combine
import Foundation
import Network

private nonisolated enum CloudKitBufferedLogKind: Sendable {
    case operation(isError: Bool)
    case debug
}

private nonisolated struct CloudKitBufferedLogEntry: Sendable {
    let date: Date
    let message: String
    let kind: CloudKitBufferedLogKind
}

/// Syncs can emit dozens of diagnostic messages in a short burst.  Buffering them
/// here keeps those messages useful without turning every one into a separate
/// MainActor hop and ObservableObject invalidation.
private actor CloudKitLogBuffer {
    static let shared = CloudKitLogBuffer()

    private var pending: [CloudKitBufferedLogEntry] = []
    private var flushTask: Task<Void, Never>?

    func append(_ message: String, kind: CloudKitBufferedLogKind) {
        pending.append(CloudKitBufferedLogEntry(date: Date(), message: message, kind: kind))
        guard flushTask == nil else { return }
        flushTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    private func flush() async {
        let entries = pending
        pending.removeAll(keepingCapacity: true)
        flushTask = nil
        guard !entries.isEmpty else { return }
        await MainActor.run {
            CloudKitSyncService.shared.status.apply(entries)
        }
    }
}

// MARK: - Sync Status (UI-facing)

@MainActor
final class CloudKitSyncStatus: ObservableObject {
    @Published var lastSyncDate: Date?
    @Published var isSyncing = false
    @Published var currentMessage: String?
    @Published var pendingScrobbles = 0
    @Published var lastError: String?
    @Published var accountAvailable = true
    @Published var logEntries: [String] = []
    @Published var debugLogEntries: [String] = []

    nonisolated init() {}

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    fileprivate func apply(_ entries: [CloudKitBufferedLogEntry]) {
        var operations: [String] = []
        var debug: [String] = []
        var newestError: String?

        for entry in entries {
            let stamp = Self.timeFormatter.string(from: entry.date)
            let formatted = "[\(stamp)] \(entry.message)"
            switch entry.kind {
            case .operation(let isError):
                operations.append(formatted)
                debug.append("[\(stamp)] [CloudKitSync] \(entry.message)")
                if isError { newestError = entry.message }
            case .debug:
                debug.append(formatted)
            }
        }

        if !operations.isEmpty {
            logEntries = Array((operations.reversed() + logEntries).prefix(100))
        }
        if !debug.isEmpty {
            debugLogEntries = Array((debug.reversed() + debugLogEntries).prefix(500))
        }
        if let newestError { lastError = newestError }
    }
}

private nonisolated struct CloudDownloadStats: Sendable {
    var settingsDownloaded = 0
    var settingsDeleted = 0

    mutating func add(_ other: CloudDownloadStats) {
        settingsDownloaded += other.settingsDownloaded
        settingsDeleted += other.settingsDeleted
    }
}

private enum CloudSyncCategory: String, CaseIterable {
    case lyricsServer
    case uiCustomizations
    case externalServices

    nonisolated var displayName: String {
        switch self {
        case .lyricsServer: return "Lyrics Server"
        case .uiCustomizations: return "UI Customizations"
        case .externalServices: return "External Services"
        }
    }

    nonisolated var tokenKey: String {
        switch self {
        case .lyricsServer: return "shelv_ck_zone_token_lyrics_server"
        case .uiCustomizations: return "shelv_ck_zone_token_ui_customizations"
        case .externalServices: return "shelv_ck_zone_token_external_services"
        }
    }

    nonisolated func handles(recordType: CKRecord.RecordType) -> Bool {
        switch self {
        case .lyricsServer:
            return recordType == "LyricsServerSettings"
        case .uiCustomizations:
            return recordType == "UICustomizationSettings"
        case .externalServices:
            return recordType == "ExternalServicesSettings"
        }
    }
}

private nonisolated struct CloudUICustomizationPayload: Codable, Sendable {
    let schemaVersion: Int
    let values: [String: PersonalizationCloudValue]
}

// MARK: - CloudKit call timeout

/// CKDatabase operations have no built-in timeout and can hang indefinitely on networks
/// where iCloud traffic is degraded or blocked (unlike our Subsonic HTTP calls, which set
/// `requestTimeout`). This wraps any CloudKit call so a hang surfaces as a normal failure
/// after `seconds` instead of blocking whatever awaits it forever. The underlying operation
/// isn't cancelled — a wedged CKOperation isn't guaranteed to respond to cancellation — it's
/// simply abandoned and its eventual result discarded via the resume guard.
struct CKOperationTimeoutError: Error {}

private actor CKTimeoutResumeGuard {
    private var didResume = false
    func tryResume() -> Bool {
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

private func withCKTimeout<T: Sendable>(
    seconds: TimeInterval = 15,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let resumeGuard = CKTimeoutResumeGuard()
    return try await withCheckedThrowingContinuation { continuation in
        Task {
            do {
                let value = try await operation()
                if await resumeGuard.tryResume() {
                    continuation.resume(returning: value)
                }
            } catch {
                if await resumeGuard.tryResume() {
                    continuation.resume(throwing: error)
                }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if await resumeGuard.tryResume() {
                continuation.resume(throwing: CKOperationTimeoutError())
            }
        }
    }
}

/// A fixed wall-clock budget (`withCKTimeout` above) is wrong for a multi-page fetch like
/// `CKFetchRecordZoneChangesOperation`: a large one-time backlog (e.g. a fresh account, or
/// a reset change token) can legitimately take longer than any single call's budget while
/// still actively receiving pages. This tracks *activity* instead — any record/deletion/
/// token callback resets the clock — so only genuine silence (nothing at all for `seconds`)
/// counts as a hang. Plain lock instead of an actor: callbacks fire per-record from
/// CKOperation's own queue, and hopping through an actor for every single record would add
/// needless overhead for what's just an integer bump.
private nonisolated final class CKActivityWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var isCancelled = false

    func markActivity() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        isCancelled = true
    }

    /// Polls in `seconds`-sized windows. Returns `true` once a full window passes with no
    /// recorded activity, `false` if cancelled (i.e. the operation finished normally) first.
    func waitForInactivity(seconds: TimeInterval) async -> Bool {
        while true {
            let before = generationSnapshot()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let (after, cancelled) = stateSnapshot()
            if cancelled { return false }
            if after == before { return true }
        }
    }

    private func generationSnapshot() -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    private func stateSnapshot() -> (Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (generation, isCancelled)
    }
}

// MARK: - CloudKitSyncService

actor CloudKitSyncService {
    static let shared = CloudKitSyncService()

    nonisolated let status = CloudKitSyncStatus()

    private let container  = CKContainer(identifier: "iCloud.ch.vkugler.Shelv")
    private var db: CKDatabase { container.privateCloudDatabase }
    private let zoneID     = CKRecordZone.ID(zoneName: "ShelvSyncZone",
                                              ownerName: CKCurrentUserDefaultName)
    /// Where records lived before the zone was renamed. `migrateLegacyZoneIfNeeded()`
    /// copies them across and only then deletes it, so nothing is lost on the way.
    private let legacyZoneID = CKRecordZone.ID(zoneName: RemovedFeatureCleanup.legacyCloudZoneName,
                                               ownerName: CKCurrentUserDefaultName)
    private static let legacyZoneMigratedKey = "shelv_ck_zone_migrated_v1"

    private let legacyTokenKey = "shelv_ck_zone_token"
    private let deviceIdKey = "shelv_device_id"
    private let syncEnabledKey = "iCloudSyncEnabled"
    private let lyricsServerSyncEnabledKey = "iCloudSyncLyricsServerEnabled"
    private let radioStationsSyncEnabledKey = "iCloudSyncRadioStationsEnabled"
    private let uiCustomizationsSyncEnabledKey = "iCloudSyncUICustomizationsEnabled"
    private let externalServicesSyncEnabledKey = "iCloudSyncExternalServicesEnabled"
    private let queueSyncModeKey = "queueSyncMode"

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

    private static let externalServicesRecordName = "external_services_settings"

    /// Play history records are no longer synced. Every device removes the
    /// ones left in the zone once, so nothing downloads them again.
    private static let legacyPlayEventRecordType = "PlayEvent"
    private static let legacyPlayEventsPurgedKey = "shelv_ck_play_events_purged_v1"

    private var isZoneReady = false
    private var lastDisabledLogAt: [String: Date] = [:]
    private let minimumVisibleStatusDuration: TimeInterval = 3
    private var isSyncWorkflowRunning = false
    private var isSyncNowWorkflowRunning = false
    private var syncNowCompletionGeneration: UInt64 = 0
    private var syncWorkflowWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentStatusChangedAt = Date.distantPast
    private var isApplyingRemoteUICustomizations = false
    private var lastUICustomizationSnapshot: [String: PersonalizationCloudValue]?

    private var syncEnabled: Bool {
        if UserDefaults.standard.object(forKey: syncEnabledKey) == nil { return false }
        return UserDefaults.standard.bool(forKey: syncEnabledKey)
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

    private var externalServicesSyncEnabled: Bool {
        boolDefaultingToTrue(forKey: externalServicesSyncEnabledKey)
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
        case .lyricsServer: return lyricsServerSyncEnabled
        case .uiCustomizations: return uiCustomizationsSyncEnabled
        case .externalServices: return externalServicesSyncEnabled
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
        isSyncNowWorkflowRunning = false
        return true
    }

    private func endSyncWorkflow() {
        isSyncWorkflowRunning = false
        let waiters = syncWorkflowWaiters
        syncWorkflowWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    /// Automatic sync requests coalesce, but every caller waits until the one
    /// follow-up run that covers its request has actually completed.
    private func acquireSyncNowWorkflow() async -> Bool {
        let targetGeneration = syncNowCompletionGeneration &+ (
            isSyncWorkflowRunning && isSyncNowWorkflowRunning ? 2 : 1
        )
        var didLogQueue = false

        while syncNowCompletionGeneration < targetGeneration {
            if !isSyncWorkflowRunning {
                isSyncWorkflowRunning = true
                isSyncNowWorkflowRunning = true
                return true
            }
            if !didLogQueue {
                log("Sync queued — another sync is already running")
                didLogQueue = true
            }
            await withCheckedContinuation { continuation in
                syncWorkflowWaiters.append(continuation)
            }
        }
        return false
    }

    private func endSyncNowWorkflow() {
        isSyncNowWorkflowRunning = false
        syncNowCompletionGeneration &+= 1
        endSyncWorkflow()
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
        writeUserDefault(value, forKey: key)
    }

    private nonisolated static func writeUserDefault(_ value: UserDefaultValue, forKey key: String) {
        let defaults = UserDefaults.standard
        switch value {
        case .bool(let value):
            guard defaults.object(forKey: key) as? Bool != value else { return }
            defaults.set(value, forKey: key)
        case .string(let value):
            guard defaults.string(forKey: key) != value else { return }
            defaults.set(value, forKey: key)
        case .data(let value):
            guard defaults.data(forKey: key) != value else { return }
            defaults.set(value, forKey: key)
        case .stringArray(let value):
            guard defaults.stringArray(forKey: key) != value else { return }
            defaults.set(value, forKey: key)
        case .int(let value):
            guard defaults.object(forKey: key) as? Int != value else { return }
            defaults.set(value, forKey: key)
        case .double(let value):
            guard defaults.object(forKey: key) as? Double != value else { return }
            defaults.set(value, forKey: key)
        }
    }

    private nonisolated static func removeUserDefault(forKey key: String) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
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
                await BackgroundWorkCoordinator.shared.run(.cloudSync) {
                    await CloudKitSyncService.shared.syncNow()
                }
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
            // This gates every sync entry point (syncNow, flushAndWait, category changes) —
            // a hang here would defeat the whole point of timing out the calls it guards.
            let s = try await withCKTimeout { [container] in try await container.accountStatus() }
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
            let saved = try await withCKTimeout { [db, zoneID] in try await db.save(CKRecordZone(zoneID: zoneID)) }
            debug("[CloudKitSync] Zone save returned: \(saved.zoneID)")
            isZoneReady = true
            await migrateLegacyZoneIfNeeded()
        } catch {
            debug("[CloudKitSync] Zone save FAILED: \(error)")
            debug("[CloudKitSync] Zone save error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                debug("[CloudKitSync] Zone CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            throw error
        }
    }

    /// Moves everything out of the previously used zone.
    ///
    /// Play history and settings live there for anyone upgrading, and the local
    /// database alone cannot rebuild what other devices contributed. Records are
    /// copied first and the old zone is deleted only once that succeeded; any
    /// failure leaves it untouched and the next sync tries again.
    private func migrateLegacyZoneIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.legacyZoneMigratedKey) else { return }

        let carried: [CKRecord]
        do {
            carried = try await fetchAllLegacyZoneRecords()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Nothing to move: a fresh install, or the zone is already gone.
            UserDefaults.standard.set(true, forKey: Self.legacyZoneMigratedKey)
            return
        } catch {
            debug("[CloudKitSync] Legacy zone read failed, will retry: \(error.localizedDescription)")
            return
        }

        // Records of the removed feature are simply left behind.
        let movable = carried.filter { !RemovedFeatureCleanup.legacyCloudRecordTypes.contains($0.recordType) }
        if !movable.isEmpty {
            let rebuilt = movable.map { old -> CKRecord in
                let copy = CKRecord(
                    recordType: old.recordType,
                    recordID: CKRecord.ID(recordName: old.recordID.recordName, zoneID: zoneID)
                )
                for key in old.allKeys() { copy[key] = old[key] }
                return copy
            }
            do {
                for chunk in stride(from: 0, to: rebuilt.count, by: 300).map({
                    Array(rebuilt[$0..<min($0 + 300, rebuilt.count)])
                }) {
                    _ = try await withCKTimeout { [db] in
                        try await db.modifyRecords(saving: chunk, deleting: [], savePolicy: .allKeys)
                    }
                }
            } catch {
                debug("[CloudKitSync] Legacy zone copy failed, will retry: \(error.localizedDescription)")
                return
            }
            debug("[CloudKitSync] Carried \(rebuilt.count) records over from the previous zone")
        }

        do {
            _ = try await withCKTimeout { [db, legacyZoneID] in
                try await db.deleteRecordZone(withID: legacyZoneID)
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            // Already gone, nothing to do.
        } catch {
            debug("[CloudKitSync] Old zone delete failed, will retry: \(error.localizedDescription)")
            return
        }
        UserDefaults.standard.set(true, forKey: Self.legacyZoneMigratedKey)
        debug("[CloudKitSync] Previous zone removed")
    }

    private func fetchAllLegacyZoneRecords() async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        while true {
            // Explizit kopieren: die Closure ist Sendable und `token` wird nach
            // dem Aufruf weitergeschrieben.
            let pageToken = token
            let result = try await withCKTimeout { [db, legacyZoneID, pageToken] in
                try await db.recordZoneChanges(
                    inZoneWith: legacyZoneID,
                    since: pageToken
                )
            }
            for change in result.modificationResultsByID.values {
                if let record = try? change.get().record { records.append(record) }
            }
            token = result.changeToken
            guard result.moreComing else { break }
        }
        return records
    }

    // MARK: - Legacy play history

    /// Deletes every play history record an older version left in the zone.
    /// Only record IDs are fetched, which keeps this cheap even for a large
    /// history. Runs once per device and retries on the next sync if it fails.
    private func purgeLegacyPlayEventsIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.legacyPlayEventsPurgedKey) else { return }
        guard canSyncBase, await status.accountAvailable else { return }
        do {
            try await ensureZoneExists()
            var ids: [CKRecord.ID] = []
            var token: CKServerChangeToken?
            while true {
                let pageToken = token
                let result = try await withCKTimeout(seconds: 30) { [db, zoneID, pageToken] in
                    try await db.recordZoneChanges(
                        inZoneWith: zoneID,
                        since: pageToken,
                        desiredKeys: []
                    )
                }
                for (id, change) in result.modificationResultsByID {
                    if let record = try? change.get().record,
                       record.recordType == Self.legacyPlayEventRecordType {
                        ids.append(id)
                    }
                }
                token = result.changeToken
                guard result.moreComing else { break }
            }
            try await deleteRecordsTolerantly(ids)
            Self.setUserDefault(.bool(true), forKey: Self.legacyPlayEventsPurgedKey)
            if !ids.isEmpty {
                log("Removed \(ids.count) old plays from iCloud")
            }
        } catch {
            if isZoneNotFound(error) {
                Self.setUserDefault(.bool(true), forKey: Self.legacyPlayEventsPurgedKey)
                return
            }
            log("Removing old plays from iCloud failed — will retry on next sync: \(error.localizedDescription)", isError: true)
        }
    }

    /// Deletes records in batches. Records that are already gone count as
    /// deleted; any other failure throws so the caller can try again later.
    private func deleteRecordsTolerantly(_ ids: [CKRecord.ID]) async throws {
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let (_, deleteResults) = try await withCKTimeout { [db] in
                try await db.modifyRecords(saving: [], deleting: chunk, atomically: false)
            }
            for id in chunk {
                guard let result = deleteResults[id] else { throw CKError(.partialFailure) }
                if case .failure(let error) = result, !Self.isGoneError(error) {
                    throw error
                }
            }
        }
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
            let (records, deletions, newToken, timedOut) = try await fetchZoneChanges(previousToken: token)
            debug("[CloudKitSync] Received \(records.count) new records, \(deletions.count) deletions for \(category.displayName)\(timedOut ? " (partial — still catching up)" : "")")

            let settingsDel = deletions.filter { category.handles(recordType: $0.1) }.count
            var settingsIn = 0
            var stalePlayEvents: [CKRecord.ID] = []
            for record in records {
                if record.recordType == Self.legacyPlayEventRecordType {
                    stalePlayEvents.append(record.recordID)
                    continue
                }
                guard category.handles(recordType: record.recordType) else { continue }
                settingsIn += await handleIncomingRecord(record).settingsDownloaded
            }
            stats.settingsDownloaded = settingsIn
            stats.settingsDeleted = settingsDel
            switch category {
            case .lyricsServer: await pushLyricsServerSettingsIfNeeded()
            case .uiCustomizations: await pushUICustomizationsIfNeeded()
            case .externalServices: await pushExternalServicesIfNeeded()
            }
            if let token = newToken { setChangeToken(token, for: category) }
            // A device still on an older version may keep uploading plays.
            // Once the one-time purge is done, those are removed as they show up.
            if !stalePlayEvents.isEmpty,
               UserDefaults.standard.bool(forKey: Self.legacyPlayEventsPurgedKey) {
                try? await deleteRecordsTolerantly(stalePlayEvents)
            }
            log("Downloaded \(category.displayName): \(settingsIn > 0 ? "\(settingsIn) settings" : "no changes")\(timedOut ? " — still catching up, will continue next sync" : "")")
            if settingsDel > 0 {
                log("Deleted on other device (\(category.displayName)): \(settingsDel) settings")
            }
            await MainActor.run { status.lastSyncDate = Date() }
        } catch {
            debug("[CloudKitSync] \(category.displayName) download error: \(error)")
            debug("[CloudKitSync] Download error description: \(error.localizedDescription)")
            if let ck = error as? CKError {
                debug("[CloudKitSync] Download CKError code=\(ck.code.rawValue) (\(ck.code)) userInfo=\(ck.userInfo)")
            }
            if isZoneNotFound(error) {
                markLocalAsUnsyncedForReUpload()
                setChangeToken(nil, for: category)
                isZoneReady = false
                log("iCloud zone was reset on another device — marking local \(category.displayName) data for re-upload")
            } else if isChangeTokenExpired(error) {
                // Zone was wiped and recreated on another device (typical when that device
                // re-enabled sync in the same flow). Treat like zoneNotFound so our local
                // truth gets re-uploaded.
                markLocalAsUnsyncedForReUpload()
                setChangeToken(nil, for: category)
                isZoneReady = false
                log("Change token expired for \(category.displayName) — marking local data for re-upload")
            } else {
                log("\(category.displayName) download error: \(error.localizedDescription)", isError: true)
            }
        }
        return stats
    }

    /// `timedOut` means the fetch didn't finish within `inactivityTimeout` seconds of *no*
    /// callback activity — `changed`/`deleted`/`token` still reflect whatever was received
    /// up to that point (not discarded), so the caller can apply and persist that partial
    /// progress instead of repeating the whole backlog from scratch next time. The
    /// underlying operation isn't cancelled (a wedged CKOperation isn't guaranteed to
    /// respond to cancellation) — just abandoned; its eventual result, if any arrives late,
    /// is discarded via the resume guard.
    private func fetchZoneChanges(
        previousToken: CKServerChangeToken?,
        inactivityTimeout: TimeInterval = 30
    ) async throws -> (changed: [CKRecord], deleted: [(CKRecord.ID, CKRecord.RecordType)], token: CKServerChangeToken?, timedOut: Bool) {
        let resumeGuard = CKTimeoutResumeGuard()
        let watchdog = CKActivityWatchdog()

        return try await withCheckedThrowingContinuation { continuation in
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
                watchdog.markActivity()
                if case .success(let record) = result { changed.append(record) }
            }

            op.recordWithIDWasDeletedBlock = { recordID, recordType in
                watchdog.markActivity()
                deleted.append((recordID, recordType))
            }

            op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                watchdog.markActivity()
                if let token { latestToken = token }
            }

            op.recordZoneFetchResultBlock = { _, result in
                watchdog.markActivity()
                switch result {
                case .success(let (token, _, _)):
                    latestToken = token
                case .failure(let err):
                    zoneError = err
                }
            }

            op.fetchRecordZoneChangesResultBlock = { result in
                watchdog.cancel()
                Task {
                    guard await resumeGuard.tryResume() else { return }
                    if let zoneError {
                        continuation.resume(throwing: zoneError)
                        return
                    }
                    switch result {
                    case .success:
                        continuation.resume(returning: (changed, deleted, latestToken, false))
                    case .failure(let err):
                        continuation.resume(throwing: err)
                    }
                }
            }

            Task {
                guard await watchdog.waitForInactivity(seconds: inactivityTimeout) else { return }
                guard await resumeGuard.tryResume() else { return }
                continuation.resume(returning: (changed, deleted, latestToken, true))
            }

            db.add(op)
        }
    }

    private func handleIncomingRecord(_ record: CKRecord) async -> CloudDownloadStats {
        var stats = CloudDownloadStats()
        switch record.recordType {
        case "LyricsServerSettings":
            guard canSync(.lyricsServer) else { return stats }
            applyIncomingLyricsServerSettings(record)
            stats.settingsDownloaded = 1

        case "UICustomizationSettings":
            guard canSync(.uiCustomizations) else { return stats }
            applyIncomingUICustomizations(record)
            stats.settingsDownloaded = 1

        case "ExternalServicesSettings":
            guard canSync(.externalServices) else { return stats }
            if await applyIncomingExternalServices(record) {
                stats.settingsDownloaded = 1
            }

        default:
            break
        }
        return stats
    }

    private static func isGoneError(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        return ck.code == .unknownItem || ck.code == .zoneNotFound
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
        guard await status.accountAvailable else { return }
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
            _ = try await withCKTimeout { [db] in
                try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: true)
            }
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
        guard await status.accountAvailable else { return }

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
            _ = try await withCKTimeout { [db] in
                try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: true)
            }
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

    // MARK: - Shared external services

    /// Call after the user changed anything about a connected service, so the
    /// new state wins over what iCloud holds and reaches the other devices.
    func recordExternalServicesChange() async {
        Self.setUserDefault(.double(Date().timeIntervalSince1970), forKey: ExternalServicesSync.updatedAtKey)
        guard canSync(.externalServices) else {
            logDisabled(.externalServices, action: "external services upload")
            return
        }
        await pushExternalServicesIfNeeded()
    }

    func pushExternalServicesIfNeeded() async {
        guard canSync(.externalServices) else { return }
        guard await status.accountAvailable else { return }
        let updatedAt = UserDefaults.standard.double(forKey: ExternalServicesSync.updatedAtKey)
        let syncedAt = UserDefaults.standard.double(forKey: ExternalServicesSync.syncedAtKey)
        guard updatedAt > syncedAt else { return }

        let snapshot = LastFMCredentialStore.snapshot()
        do {
            try await ensureZoneExists()
            let rid = CKRecord.ID(recordName: Self.externalServicesRecordName, zoneID: zoneID)
            let rec = CKRecord(recordType: "ExternalServicesSettings", recordID: rid)
            rec["lastFMEnabled"] = snapshot.isEnabled ? 1 : 0
            rec["lastFMMixesEnabled"] = snapshot.mixesEnabled ? 1 : 0
            rec["lastFMTopSongsEnabled"] = snapshot.topSongsEnabled ? 1 : 0
            rec["lastFMUsername"] = snapshot.username
            // Keys and the session grant access to the account, so they only
            // travel end-to-end encrypted.
            rec.encryptedValues["lastFMAPIKey"] = snapshot.apiKey
            rec.encryptedValues["lastFMSharedSecret"] = snapshot.sharedSecret
            rec.encryptedValues["lastFMSessionKey"] = snapshot.sessionKey
            rec["updatedAt"] = updatedAt
            rec["deviceId"] = deviceId
            _ = try await withCKTimeout { [db] in
                try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: true)
            }
            Self.setUserDefault(.double(updatedAt), forKey: ExternalServicesSync.syncedAtKey)
            log("External services uploaded")
        } catch {
            log("External services upload failed — will retry on next sync: \(error.localizedDescription)", isError: true)
        }
    }

    private func applyIncomingExternalServices(_ record: CKRecord) async -> Bool {
        guard let updatedAt = record["updatedAt"] as? Double else { return false }
        let localUpdated = UserDefaults.standard.double(forKey: ExternalServicesSync.updatedAtKey)
        guard updatedAt > localUpdated else { return false }

        let snapshot = LastFMCloudSnapshot(
            isEnabled: (record["lastFMEnabled"] as? Int64 ?? 0) == 1,
            // Records written before these options existed carry neither,
            // which means both were on.
            mixesEnabled: (record["lastFMMixesEnabled"] as? Int64).map { $0 == 1 } ?? true,
            topSongsEnabled: (record["lastFMTopSongsEnabled"] as? Int64).map { $0 == 1 } ?? true,
            username: record["lastFMUsername"] as? String ?? "",
            apiKey: record.encryptedValues["lastFMAPIKey"] as? String ?? "",
            sharedSecret: record.encryptedValues["lastFMSharedSecret"] as? String ?? "",
            sessionKey: record.encryptedValues["lastFMSessionKey"] as? String ?? ""
        )
        guard LastFMCredentialStore.apply(snapshot) else {
            log("External services from iCloud could not be stored — will retry on next sync", isError: true)
            return false
        }
        Self.setUserDefault(.double(updatedAt), forKey: ExternalServicesSync.updatedAtKey)
        Self.setUserDefault(.double(updatedAt), forKey: ExternalServicesSync.syncedAtKey)
        await LastFMService.shared.credentialsDidChange()
        log("External services updated from iCloud")
        return true
    }

    func deleteZone(force: Bool = false) async {
        guard syncEnabled || force else { return }
        await MainActor.run { status.isSyncing = true }
        log("Deleting iCloud zone…")
        do {
            _ = try await withCKTimeout { [db, zoneID] in try await db.deleteRecordZone(withID: zoneID) }
            isZoneReady = false
            clearChangeTokens()
            markLocalAsUnsyncedForReUpload()
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
                markLocalAsUnsyncedForReUpload()
                log("iCloud zone already gone")
            } else {
                log("Zone deletion failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func markLocalAsUnsyncedForReUpload() {
        // Lyrics-/UI-Settings sind account-unabhängig: nach einem Zone-Wipe den lokalen
        // Stand neu hochladbar machen, damit er nicht aus iCloud verschwindet.
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
        if UserDefaults.standard.double(forKey: ExternalServicesSync.updatedAtKey) > 0 {
            Self.setUserDefault(.double(0), forKey: ExternalServicesSync.syncedAtKey)
        }
    }

    // MARK: - PlayQueue (geräteübergreifende Wiedergabe-Queue)

    // Eigenes Gate, bewusst unabhängig vom Settings-Sync (`syncEnabled`).
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
            let saveResults = try await withCKTimeout { [db] in
                try await db.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: true
                ).saveResults
            }
            guard let result = saveResults[record.recordID] else {
                debug("[CloudKitSync] PlayQueue save returned no record result")
                return false
            }
            if case .failure(let error) = result {
                debug("[CloudKitSync] PlayQueue save failed: \(error.localizedDescription)")
                return false
            }
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
            let recordID = playQueueRecordID(serverId: serverId)
            let record = try await withCKTimeout(seconds: 10) { [db] in try await db.record(for: recordID) }
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
        if !(await status.accountAvailable) {
            guard await refreshAccountAvailability(action: "Radio metadata fetch") else { return [] }
        }
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
                let recordID = radioMetadataRecordID(recordName: name)
                let record = try await withCKTimeout(seconds: 10) { [db] in try await db.record(for: recordID) }
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
            _ = try await withCKTimeout { [db] in
                try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
            }
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
            let recordID = radioMetadataRecordID(recordName: recordName)
            _ = try await withCKTimeout { [db] in try await db.deleteRecord(withID: recordID) }
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
        guard await acquireSyncNowWorkflow() else { return }
        defer { endSyncNowWorkflow() }

        // Queue-Sync hängt an einem eigenen Toggle und läuft unabhängig vom Play-Log-Sync.
        // Bei jedem Sync-Auslöser (Foreground, Pull-to-Refresh, Mac-Refresh, Netz-Reconnect)
        // die Remote-Queue mitprüfen — so wird ein fremder Stand zuverlässig überall erkannt.
        await QueueSyncService.shared.checkForRemoteQueue()
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
        await purgeLegacyPlayEventsIfNeeded()
        await runVisibleStatusStep(statusText("sync_status_checking_icloud")) {
            _ = await downloadChanges()
        }
        await pushLyricsServerSettingsIfNeeded()
        await pushUICustomizationsIfNeeded()
        await pushExternalServicesIfNeeded()
        await refreshRadioStationsIfNeeded()
        await finishCurrentStatus(statusText("sync_status_complete"))
        log("Sync done")
    }

    // MARK: - Pending Counts

    func updatePendingCounts() async {
        let scrobbles = await ScrobbleOutbox.shared.pendingScrobbleCount()
        await MainActor.run {
            status.pendingScrobbles = scrobbles
        }
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

        log("iCloud sync enabled — merging local and iCloud data")
        guard await refreshAccountAvailability(action: "Initial iCloud sync") else {
            await finishCurrentStatus(statusText("sync_status_idle"))
            return
        }

        await runVisibleStatusStep(statusText("sync_status_preparing_icloud")) {
            await setup()
            resetChangeToken(for: .uiCustomizations)
            resetChangeToken(for: .externalServices)
        }

        await purgeLegacyPlayEventsIfNeeded()

        await runVisibleStatusStep(statusText("sync_status_verifying_icloud")) {
            _ = await downloadChanges()
        }

        await finishCurrentStatus(statusText("sync_status_complete"))
        await MainActor.run { status.lastSyncDate = Date() }
        log("Initial iCloud sync complete")
    }

    func handleSyncCategoryChange() async {
        guard beginSyncWorkflow(named: "What to Sync update") else { return }
        defer { endSyncWorkflow() }

        log("What to Sync updated — Lyrics Server: \(lyricsServerSyncEnabled ? "on" : "off"), Radio Stations: \(radioStationsSyncEnabled ? "on" : "off"), UI Customizations: \(uiCustomizationsSyncEnabled ? "on" : "off"), External Services: \(externalServicesSyncEnabled ? "on" : "off")")
        guard canSyncBase else {
            logDisabled(nil, action: "What to Sync update")
            return
        }
        guard await refreshAccountAvailability(action: "What to Sync update") else { return }
        await runVisibleStatusStep(statusText("sync_status_checking_icloud")) {
            _ = await downloadChanges()
        }
        if canSync(.lyricsServer) {
            await pushLyricsServerSettingsIfNeeded()
        }
        await refreshRadioStationsIfNeeded()
        if canSync(.uiCustomizations) {
            await pushUICustomizationsIfNeeded()
        }
        if canSync(.externalServices) {
            await pushExternalServicesIfNeeded()
        }
        await updatePendingCounts()
        await finishCurrentStatus(statusText("sync_status_complete"))
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
        Task(priority: .utility) {
            await CloudKitLogBuffer.shared.append(message, kind: .operation(isError: isError))
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
        Task(priority: .utility) {
            await CloudKitLogBuffer.shared.append(message, kind: .debug)
        }
    }

    nonisolated static func debugLog(_ message: String) {
        print(message)
        Task(priority: .utility) {
            await CloudKitLogBuffer.shared.append(message, kind: .debug)
        }
    }

}

// MARK: - Errors

enum CKSyncError: LocalizedError {
    case timeout
    var errorDescription: String? { "iCloud-Sync Timeout" }
}
