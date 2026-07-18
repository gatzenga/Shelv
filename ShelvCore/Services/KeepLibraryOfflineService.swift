import Combine
import Foundation

@MainActor
final class KeepLibraryOfflineService: ObservableObject {
    static let shared = KeepLibraryOfflineService()
    static let storageReserveRatio = 0.15
    static let storageRetryThresholdBytes: Int64 = 1_000_000_000

    @Published private(set) var status: KeepLibraryOfflineStatus = .inactive
    @Published private(set) var lowStorageBannerVisible = false

    private var activeServerId: String?
    private var checkingServerIds = Set<String>()
    private var pendingManualCancelServers = Set<String>()
    private var pendingLowStorageFailureServers = Set<String>()
    private var lowStorageFailureSignatures: [String: String] = [:]
    private var lowStorageBannerDismissTask: Task<Void, Never>?

    private init() {}

    func isEnabled(serverId: String?) -> Bool {
        guard let serverId, !serverId.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: enabledKey(serverId: serverId))
    }

    func setEnabled(_ enabled: Bool, serverId: String) {
        guard !serverId.isEmpty else { return }
        UserDefaults.standard.set(enabled, forKey: enabledKey(serverId: serverId))
        activeServerId = serverId
        if enabled {
            clearStoragePause(serverId: serverId)
            pendingManualCancelServers.remove(serverId)
            lowStorageFailureSignatures.removeValue(forKey: serverId)
            pendingLowStorageFailureServers.remove(serverId)
            status = .idle
        } else {
            pendingManualCancelServers.remove(serverId)
            lowStorageFailureSignatures.removeValue(forKey: serverId)
            pendingLowStorageFailureServers.remove(serverId)
            clearStoragePause(serverId: serverId)
            status = .inactive
            setLowStorageBannerVisible(false)
        }
    }

    func disableAndCancel(serverId: String) {
        setEnabled(false, serverId: serverId)
        Task { await DownloadService.shared.cancelBatch() }
    }

    func cancelCurrentRun(serverId: String) {
        guard isEnabled(serverId: serverId) else {
            Task { await DownloadService.shared.cancelBatch() }
            return
        }
        activeServerId = serverId
        pendingManualCancelServers.insert(serverId)
        status = .idle
        setLowStorageBannerVisible(false)
        Task { [weak self] in
            await DownloadService.shared.cancelBatch()
            await MainActor.run {
                guard let self, !self.checkingServerIds.contains(serverId) else { return }
                self.pendingManualCancelServers.remove(serverId)
            }
        }
    }

    func markDownloadStorageFailure(serverId: String, failedSong: Song? = nil) {
        guard isEnabled(serverId: serverId) else { return }
        pendingLowStorageFailureServers.insert(serverId)
        setFullyPaused(true, serverId: serverId)
        let availableBytes = Self.availableDiskBytes()
        saveStoragePause(
            serverId: serverId,
            availableBytes: availableBytes,
            reserveFloorBytes: availableBytes
        )
        guard isPresentedServer(serverId) else { return }
        status = .pausedLowStorage
        setLowStorageBannerVisible(shouldShowLowStorageBanner(serverId: serverId))
    }

    func prepare(serverId: String) {
        activeServerId = serverId
        guard isEnabled(serverId: serverId) else {
            status = .inactive
            setLowStorageBannerVisible(false)
            return
        }
        if pendingLowStorageFailureServers.contains(serverId)
            || isFullyPaused(serverId: serverId) {
            status = .pausedLowStorage
            setLowStorageBannerVisible(shouldShowLowStorageBanner(serverId: serverId))
        } else {
            status = .idle
            setLowStorageBannerVisible(false)
        }
    }

    func dismissLowStorageBanner() {
        setLowStorageBannerVisible(false)
    }

    func markDownloadsStarted(serverId: String) {
        guard isEnabled(serverId: serverId), isPresentedServer(serverId) else { return }
        setFullyPaused(false, serverId: serverId)
        setLowStorageBannerVisible(false)
        status = .downloading
    }

    func markPausedLowStorage(serverId: String, skippedSongs: [Song] = []) {
        guard isEnabled(serverId: serverId) else { return }
        setFullyPaused(true, serverId: serverId)
        if !skippedSongs.isEmpty {
            let availableBytes = Self.availableDiskBytes()
            saveStoragePause(
                serverId: serverId,
                availableBytes: availableBytes,
                reserveFloorBytes: availableBytes
            )
        }
        guard isPresentedServer(serverId) else { return }
        status = .pausedLowStorage
        setLowStorageBannerVisible(shouldShowLowStorageBanner(serverId: serverId))
    }

    func rememberStoragePause(serverId: String, availableBytes: Int64?, plan: BulkDownloadPlan) {
        guard isEnabled(serverId: serverId), !plan.skipped.isEmpty else { return }
        setFullyPaused(false, serverId: serverId)
        saveStoragePause(
            serverId: serverId,
            availableBytes: availableBytes,
            plan: plan,
            reserveFloorBytes: storageReserveFloor(availableBytes: availableBytes, plannedBytes: plan.totalBytes)
        )
    }

    func checkAndDownload(
        serverId: String,
        libraryAlbums: [Album],
        favorites: Bool,
        recapPlaylistIds: [String],
        force: Bool = false
    ) async {
        guard canContinueCheck(serverId: serverId) else { return }
        guard !libraryAlbums.isEmpty else { return }
        guard checkingServerIds.insert(serverId).inserted else { return }

        activeServerId = serverId
        var isLowStorageCandidate = pendingLowStorageFailureServers.contains(serverId)
            || lowStorageFailureSignatures[serverId] != nil
        status = .checking
        if !isLowStorageCandidate {
            setLowStorageBannerVisible(false)
        }
        defer { checkingServerIds.remove(serverId) }

        let availableBytes = Self.availableDiskBytes()
        let existingPause = storagePause(serverId: serverId)
        if let pause = existingPause {
            if !hasEnoughStorageImprovement(since: pause, availableBytes: availableBytes) {
                setFullyPaused(true, serverId: serverId)
                status = .pausedLowStorage
                return
            }
            setFullyPaused(false, serverId: serverId)
            pendingLowStorageFailureServers.remove(serverId)
            lowStorageFailureSignatures.removeValue(forKey: serverId)
            isLowStorageCandidate = false
        }
        let maxBytes = await Self.keepOfflineBudgetBytes(
            serverId: serverId,
            availableBytes: availableBytes,
            pause: existingPause
        )
        guard canContinueCheck(serverId: serverId) else { return }
        var plan = await DownloadService.shared.planKeepLibraryOffline(
            serverId: serverId,
            maxBytes: maxBytes,
            favorites: favorites,
            recapPlaylistIds: recapPlaylistIds,
            libraryAlbums: libraryAlbums
        )
        guard canContinueCheck(serverId: serverId) else { return }
        plan = BulkDownloadPlan(
            planned: plan.planned,
            skipped: plan.skipped,
            totalBytes: plan.totalBytes,
            limitBytes: maxBytes,
            availableBytes: availableBytes,
            isKeepLibraryOffline: true,
            playlistMarkers: plan.playlistMarkers,
            recapPlaylistSongIds: plan.recapPlaylistSongIds
        )
        markCoveredPlaylists(plan.playlistMarkers)

        if plan.planned.isEmpty {
            if plan.skipped.isEmpty {
                clearStoragePause(serverId: serverId)
                status = .nothingToDo
            } else {
                setFullyPaused(true, serverId: serverId)
                saveStoragePause(
                    serverId: serverId,
                    availableBytes: availableBytes,
                    plan: plan,
                    reserveFloorBytes: availableBytes
                )
                status = .pausedLowStorage
                setLowStorageBannerVisible(shouldShowLowStorageBanner(serverId: serverId))
            }
            return
        }

        if isLowStorageCandidate {
            let planSignature = downloadPlanSignature(plan.planned)
            if pendingLowStorageFailureServers.remove(serverId) != nil {
                lowStorageFailureSignatures[serverId] = planSignature
                setFullyPaused(true, serverId: serverId)
                saveStoragePause(
                    serverId: serverId,
                    availableBytes: availableBytes,
                    plan: plan,
                    reserveFloorBytes: existingPause?.reserveFloorBytes ?? availableBytes
                )
                status = .pausedLowStorage
                setLowStorageBannerVisible(shouldShowLowStorageBanner(serverId: serverId))
                return
            }
            if lowStorageFailureSignatures[serverId] == planSignature {
                setFullyPaused(true, serverId: serverId)
                status = .pausedLowStorage
                return
            }
            lowStorageFailureSignatures.removeValue(forKey: serverId)
        }

        if !force, pendingManualCancelServers.remove(serverId) != nil {
            status = .idle
            return
        }
        pendingManualCancelServers.remove(serverId)
        setFullyPaused(false, serverId: serverId)

        if plan.skipped.isEmpty {
            clearStoragePause(serverId: serverId)
        } else {
            saveStoragePause(
                serverId: serverId,
                availableBytes: availableBytes,
                plan: plan,
                reserveFloorBytes: storageReserveFloor(availableBytes: availableBytes, plannedBytes: plan.totalBytes)
            )
        }
        status = .downloading
        await DownloadService.shared.enqueue(
            songs: plan.planned,
            serverId: serverId,
            requiresKeepLibraryOfflineEnabled: true
        )
        if pendingManualCancelServers.remove(serverId) != nil,
           isPresentedServer(serverId) {
            status = .idle
        }
    }

    func isEnqueueAuthorized(serverId: String) -> Bool {
        canContinueCheck(serverId: serverId)
            && !pendingManualCancelServers.contains(serverId)
    }

    private func canContinueCheck(serverId: String) -> Bool {
        SubsonicAPIService.shared.activeServer?.stableId == serverId
            && isEnabled(serverId: serverId)
            && !OfflineModeService.shared.isOffline
    }

    private func isPresentedServer(_ serverId: String) -> Bool {
        activeServerId == serverId
            && SubsonicAPIService.shared.activeServer?.stableId == serverId
    }

    static func availableDiskBytes() -> Int64? {
        #if os(tvOS)
        return nil
        #else
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int64(bytes)
        #endif
    }

    static func keepOfflineBudgetBytes(availableBytes: Int64?) -> Int64 {
        keepOfflineBudgetBytes(availableBytes: availableBytes, downloadedBytes: 0)
    }

    static func keepOfflineBudgetBytes(serverId: String, availableBytes: Int64?) async -> Int64 {
        let downloadedBytes = await DownloadDatabase.shared.totalBytes(serverId: serverId)
        return keepOfflineBudgetBytes(availableBytes: availableBytes, downloadedBytes: downloadedBytes)
    }

    private static func keepOfflineBudgetBytes(availableBytes: Int64?, downloadedBytes: Int64) -> Int64 {
        guard let availableBytes, availableBytes > 0 else { return 0 }
        let managedPoolBytes = availableBytes + max(0, downloadedBytes)
        let reserveBytes = Int64((Double(managedPoolBytes) * storageReserveRatio).rounded(.up))
        return max(0, availableBytes - reserveBytes)
    }

    private static func keepOfflineBudgetBytes(
        serverId: String,
        availableBytes: Int64?,
        pause: StoragePause?
    ) async -> Int64 {
        guard let availableBytes, availableBytes > 0 else { return 0 }
        let poolBudget = await keepOfflineBudgetBytes(serverId: serverId, availableBytes: availableBytes)
        guard let floor = pause?.reserveFloorBytes else {
            return poolBudget
        }
        let refillBytes = max(0, availableBytes - floor)
        return refillBytes >= storageRetryThresholdBytes ? min(refillBytes, poolBudget) : 0
    }

    private func enabledKey(serverId: String) -> String {
        "shelv_keep_library_offline_\(serverId)"
    }

    private func lowStorageBannerKey(serverId: String) -> String {
        "shelv_keep_library_offline_low_storage_signature_\(serverId)"
    }

    private func storagePauseKey(serverId: String) -> String {
        "shelv_keep_library_offline_storage_pause_\(serverId)"
    }

    private func fullyPausedKey(serverId: String) -> String {
        "shelv_keep_library_offline_fully_paused_\(serverId)"
    }

    private func isFullyPaused(serverId: String) -> Bool {
        UserDefaults.standard.bool(forKey: fullyPausedKey(serverId: serverId))
    }

    private func setFullyPaused(_ paused: Bool, serverId: String) {
        let key = fullyPausedKey(serverId: serverId)
        if paused {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func shouldShowLowStorageBanner(serverId: String) -> Bool {
        let key = lowStorageBannerKey(serverId: serverId)
        if UserDefaults.standard.bool(forKey: key) {
            return false
        }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    private func setLowStorageBannerVisible(_ visible: Bool) {
        lowStorageBannerDismissTask?.cancel()
        lowStorageBannerDismissTask = nil
        lowStorageBannerVisible = visible
        guard visible else { return }
        lowStorageBannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.dismissLowStorageBanner()
        }
    }

    private func downloadPlanSignature(_ songs: [Song]) -> String {
        songs.map(\.id).sorted().joined(separator: ",")
    }

    private func storagePause(serverId: String) -> StoragePause? {
        guard let data = UserDefaults.standard.data(forKey: storagePauseKey(serverId: serverId)) else { return nil }
        return try? JSONDecoder().decode(StoragePause.self, from: data)
    }

    private func saveStoragePause(
        serverId: String,
        availableBytes: Int64?,
        plan: BulkDownloadPlan,
        reserveFloorBytes: Int64?
    ) {
        saveStoragePause(
            serverId: serverId,
            availableBytes: availableBytes,
            reserveFloorBytes: reserveFloorBytes
        )
    }

    private func saveStoragePause(
        serverId: String,
        availableBytes: Int64?,
        reserveFloorBytes: Int64?
    ) {
        let pause = StoragePause(
            availableBytes: availableBytes,
            reserveFloorBytes: reserveFloorBytes
        )
        if let data = try? JSONEncoder().encode(pause) {
            UserDefaults.standard.set(data, forKey: storagePauseKey(serverId: serverId))
        }
    }

    private func clearStoragePause(serverId: String) {
        UserDefaults.standard.removeObject(forKey: storagePauseKey(serverId: serverId))
        UserDefaults.standard.removeObject(forKey: lowStorageBannerKey(serverId: serverId))
        setFullyPaused(false, serverId: serverId)
    }

    private func hasEnoughStorageImprovement(since pause: StoragePause, availableBytes: Int64?) -> Bool {
        guard let current = availableBytes else { return false }
        let baseline = pause.reserveFloorBytes ?? pause.availableBytes
        guard let baseline else { return false }
        return current - baseline >= Self.storageRetryThresholdBytes
    }

    private func storageReserveFloor(availableBytes: Int64?, plannedBytes: Int64) -> Int64? {
        guard let availableBytes else { return nil }
        return max(0, availableBytes - plannedBytes)
    }

    private func markCoveredPlaylists(_ markers: [BulkDownloadPlaylistMarker]) {
        guard !markers.isEmpty else { return }
        #if os(macOS)
        for marker in markers {
            DownloadStore.shared.markPlaylistDownloaded(id: marker.id, name: marker.name, songIds: marker.songIds)
        }
        #elseif os(iOS)
        for marker in markers {
            DownloadStore.shared.addOfflinePlaylist(marker.id, songIds: marker.songIds)
        }
        #endif
    }
}

private struct StoragePause: Codable {
    let availableBytes: Int64?
    let reserveFloorBytes: Int64?
}
