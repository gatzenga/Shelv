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
    private var isChecking = false
    private var pendingManualCancelServers = Set<String>()
    private var manualCancelSignatures: [String: String] = [:]
    private var pendingLowStorageFailureServers = Set<String>()
    private var lowStorageFailureSignatures: [String: String] = [:]

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
            UserDefaults.standard.removeObject(forKey: lowStorageSignatureKey(serverId: serverId))
            UserDefaults.standard.removeObject(forKey: storagePauseKey(serverId: serverId))
            manualCancelSignatures.removeValue(forKey: serverId)
            pendingManualCancelServers.remove(serverId)
            lowStorageFailureSignatures.removeValue(forKey: serverId)
            pendingLowStorageFailureServers.remove(serverId)
            status = .idle
        } else {
            manualCancelSignatures.removeValue(forKey: serverId)
            pendingManualCancelServers.remove(serverId)
            lowStorageFailureSignatures.removeValue(forKey: serverId)
            pendingLowStorageFailureServers.remove(serverId)
            UserDefaults.standard.removeObject(forKey: storagePauseKey(serverId: serverId))
            status = .inactive
            lowStorageBannerVisible = false
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
        lowStorageBannerVisible = false
        Task { await DownloadService.shared.cancelBatch() }
    }

    func markDownloadStorageFailure(serverId: String, failedSong: Song? = nil) {
        guard isEnabled(serverId: serverId) else { return }
        activeServerId = serverId
        pendingLowStorageFailureServers.insert(serverId)
        status = .pausedLowStorage
        lowStorageBannerVisible = shouldShowLowStorageBanner(
            serverId: serverId,
            skippedSongs: failedSong.map { [$0] } ?? []
        )
    }

    func prepare(serverId: String) {
        activeServerId = serverId
        status = isEnabled(serverId: serverId) ? .idle : .inactive
        lowStorageBannerVisible = false
    }

    func dismissLowStorageBanner() {
        lowStorageBannerVisible = false
    }

    func markDownloadsStarted(serverId: String) {
        guard isEnabled(serverId: serverId) else { return }
        activeServerId = serverId
        lowStorageBannerVisible = false
        status = .downloading
    }

    func markPausedLowStorage(serverId: String, skippedSongs: [Song] = []) {
        guard isEnabled(serverId: serverId) else { return }
        activeServerId = serverId
        status = .pausedLowStorage
        if !skippedSongs.isEmpty {
            saveStoragePause(
                serverId: serverId,
                availableBytes: Self.availableDiskBytes(),
                missingSignature: lowStorageSignature(serverId: serverId, skippedSongs: skippedSongs)
            )
        }
        lowStorageBannerVisible = shouldShowLowStorageBanner(serverId: serverId, skippedSongs: skippedSongs)
    }

    func checkAndDownload(
        serverId: String,
        libraryAlbums: [Album],
        favorites: Bool,
        recapPlaylistIds: [String],
        force: Bool = false
    ) async {
        guard isEnabled(serverId: serverId), !OfflineModeService.shared.isOffline else { return }
        guard !libraryAlbums.isEmpty else { return }
        guard !isChecking else { return }

        activeServerId = serverId
        let isManualCancelCandidate = pendingManualCancelServers.contains(serverId)
            || manualCancelSignatures[serverId] != nil
        let isLowStorageCandidate = pendingLowStorageFailureServers.contains(serverId)
            || lowStorageFailureSignatures[serverId] != nil
        isChecking = true
        if !isManualCancelCandidate && !isLowStorageCandidate {
            status = .checking
        }
        if !isLowStorageCandidate {
            lowStorageBannerVisible = false
        }
        defer { isChecking = false }

        let availableBytes = Self.availableDiskBytes()
        let maxBytes = Self.keepOfflineBudgetBytes(availableBytes: availableBytes)
        var plan = await DownloadService.shared.planKeepLibraryOffline(
            serverId: serverId,
            maxBytes: maxBytes,
            favorites: favorites,
            recapPlaylistIds: recapPlaylistIds,
            libraryAlbums: libraryAlbums
        )
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
        let missingSignature = lowStorageSignature(serverId: serverId, skippedSongs: plan.planned + plan.skipped)
        markCoveredPlaylists(plan.playlistMarkers)

        if let pause = storagePause(serverId: serverId),
           pause.missingSignature == missingSignature {
            if !hasEnoughStorageImprovement(since: pause, availableBytes: availableBytes) {
                status = .pausedLowStorage
                return
            }
            clearStoragePause(serverId: serverId)
            lowStorageFailureSignatures.removeValue(forKey: serverId)
        }

        if plan.planned.isEmpty {
            if plan.skipped.isEmpty {
                clearStoragePause(serverId: serverId)
                status = .idle
            } else {
                saveStoragePause(serverId: serverId, availableBytes: availableBytes, plan: plan)
                status = .pausedLowStorage
                lowStorageBannerVisible = shouldShowLowStorageBanner(serverId: serverId, skippedSongs: plan.skipped)
            }
            return
        }

        let planSignature = downloadPlanSignature(plan.planned)
        if pendingLowStorageFailureServers.remove(serverId) != nil {
            lowStorageFailureSignatures[serverId] = planSignature
            saveStoragePause(serverId: serverId, availableBytes: availableBytes, plan: plan)
            status = .pausedLowStorage
            lowStorageBannerVisible = shouldShowLowStorageBanner(serverId: serverId, skippedSongs: plan.planned + plan.skipped)
            return
        }
        if lowStorageFailureSignatures[serverId] == planSignature {
            status = .pausedLowStorage
            return
        }
        lowStorageFailureSignatures.removeValue(forKey: serverId)

        if pendingManualCancelServers.remove(serverId) != nil {
            manualCancelSignatures[serverId] = planSignature
            status = .idle
            return
        }
        if manualCancelSignatures[serverId] == planSignature {
            status = .idle
            return
        }
        manualCancelSignatures.removeValue(forKey: serverId)

        clearStoragePause(serverId: serverId)
        status = .downloading
        DownloadStore.shared.enqueueSongs(plan.planned)
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
        guard let availableBytes, availableBytes > 0 else { return 0 }
        return Int64(Double(availableBytes) * (1.0 - storageReserveRatio))
    }

    private func enabledKey(serverId: String) -> String {
        "shelv_keep_library_offline_\(serverId)"
    }

    private func lowStorageSignatureKey(serverId: String) -> String {
        "shelv_keep_library_offline_low_storage_signature_\(serverId)"
    }

    private func storagePauseKey(serverId: String) -> String {
        "shelv_keep_library_offline_storage_pause_\(serverId)"
    }

    private func shouldShowLowStorageBanner(serverId: String, skippedSongs: [Song]) -> Bool {
        let signature = lowStorageSignature(serverId: serverId, skippedSongs: skippedSongs)
        let key = lowStorageSignatureKey(serverId: serverId)
        if UserDefaults.standard.string(forKey: key) == signature {
            return false
        }
        UserDefaults.standard.set(signature, forKey: key)
        return true
    }

    private func lowStorageSignature(serverId: String, skippedSongs: [Song]) -> String {
        let ids = skippedSongs.map(\.id).sorted()
        guard !ids.isEmpty else { return "\(serverId)|no-capacity" }
        return "\(serverId)|\(ids.joined(separator: ","))"
    }

    private func downloadPlanSignature(_ songs: [Song]) -> String {
        songs.map(\.id).sorted().joined(separator: ",")
    }

    private func storagePause(serverId: String) -> StoragePause? {
        guard let data = UserDefaults.standard.data(forKey: storagePauseKey(serverId: serverId)) else { return nil }
        return try? JSONDecoder().decode(StoragePause.self, from: data)
    }

    private func saveStoragePause(serverId: String, availableBytes: Int64?, plan: BulkDownloadPlan) {
        saveStoragePause(
            serverId: serverId,
            availableBytes: availableBytes,
            missingSignature: lowStorageSignature(serverId: serverId, skippedSongs: plan.planned + plan.skipped)
        )
    }

    private func saveStoragePause(serverId: String, availableBytes: Int64?, missingSignature: String) {
        let pause = StoragePause(
            availableBytes: availableBytes,
            missingSignature: missingSignature
        )
        if let data = try? JSONEncoder().encode(pause) {
            UserDefaults.standard.set(data, forKey: storagePauseKey(serverId: serverId))
        }
    }

    private func clearStoragePause(serverId: String) {
        UserDefaults.standard.removeObject(forKey: storagePauseKey(serverId: serverId))
    }

    private func hasEnoughStorageImprovement(since pause: StoragePause, availableBytes: Int64?) -> Bool {
        guard let current = availableBytes, let previous = pause.availableBytes else { return false }
        return current - previous >= Self.storageRetryThresholdBytes
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
    let missingSignature: String
}
