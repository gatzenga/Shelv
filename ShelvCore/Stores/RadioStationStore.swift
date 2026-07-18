import Combine
import Foundation

private nonisolated struct RadioStationMetadataCacheSnapshot: Sendable {
    let metadata: [String: RadioStationMetadata]
    let revision: UInt64
}

private actor RadioStationMetadataDiskCache {
    static let shared = RadioStationMetadataDiskCache()

    private var revisions: [URL: UInt64] = [:]

    func load(from url: URL) -> [String: RadioStationMetadata] {
        loadSnapshot(from: url)
    }

    func snapshot(from url: URL) -> RadioStationMetadataCacheSnapshot {
        RadioStationMetadataCacheSnapshot(
            metadata: loadSnapshot(from: url),
            revision: revisions[url, default: 0]
        )
    }

    func revision(at url: URL) -> UInt64 {
        revisions[url, default: 0]
    }

    func replaceIfUnchanged(
        _ metadata: [RadioStationMetadata],
        expectedRevision: UInt64,
        at url: URL
    ) -> RadioStationMetadataCacheSnapshot? {
        guard revisions[url, default: 0] == expectedRevision else { return nil }
        let revision = advanceRevision(at: url)
        _ = write(metadata, to: url)
        var snapshot: [String: RadioStationMetadata] = [:]
        for item in metadata {
            if let existing = snapshot[item.recordName], existing.updatedAt > item.updatedAt {
                continue
            }
            snapshot[item.recordName] = item
        }
        return RadioStationMetadataCacheSnapshot(
            metadata: snapshot,
            revision: revision
        )
    }

    func upsert(_ metadata: RadioStationMetadata, at url: URL) -> String? {
        var local = loadSnapshot(from: url)
        local[metadata.recordName] = metadata
        advanceRevision(at: url)
        return write(Array(local.values), to: url)
    }

    func remove(recordName: String, at url: URL) -> String? {
        var local = loadSnapshot(from: url)
        local.removeValue(forKey: recordName)
        advanceRevision(at: url)
        return write(Array(local.values), to: url)
    }

    func merge(
        remote: [RadioStationMetadata],
        validRecordNames: Set<String>,
        expectedRevision: UInt64,
        at url: URL
    ) -> RadioStationMetadataCacheSnapshot? {
        guard revisions[url, default: 0] == expectedRevision else { return nil }
        var local = loadSnapshot(from: url)
        for metadata in remote {
            if let existing = local[metadata.recordName], existing.updatedAt > metadata.updatedAt {
                continue
            }
            local[metadata.recordName] = metadata
        }
        local = local.filter { validRecordNames.contains($0.key) }
        let revision = advanceRevision(at: url)
        _ = write(Array(local.values), to: url)
        return RadioStationMetadataCacheSnapshot(metadata: local, revision: revision)
    }

    @discardableResult
    private func advanceRevision(at url: URL) -> UInt64 {
        let revision = revisions[url, default: 0] &+ 1
        revisions[url] = revision
        return revision
    }

    private func loadSnapshot(from url: URL) -> [String: RadioStationMetadata] {
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode([RadioStationMetadata].self, from: data)
        else { return [:] }
        var result: [String: RadioStationMetadata] = [:]
        for item in metadata {
            if let existing = result[item.recordName], existing.updatedAt > item.updatedAt {
                continue
            }
            result[item.recordName] = item
        }
        return result
    }

    private func write(_ metadata: [RadioStationMetadata], to url: URL) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// CloudKit writes are kept in invocation order. This ensures a user edit that
/// arrives during a refresh upload is always the final remote operation.
private actor RadioStationMetadataCloudWriter {
    static let shared = RadioStationMetadataCloudWriter()

    private enum Operation {
        case save(RadioStationMetadata, generation: UInt64)
        case delete(String, generation: UInt64)

        var recordName: String {
            switch self {
            case .save(let metadata, _): metadata.recordName
            case .delete(let recordName, _): recordName
            }
        }

        var generation: UInt64 {
            switch self {
            case .save(_, let generation), .delete(_, let generation): generation
            }
        }
    }

    private struct Request {
        let operation: Operation
        let continuation: CheckedContinuation<Void, Never>
    }

    private var pending: [Request] = []
    private var isDraining = false
    private var latestGeneration: [String: UInt64] = [:]

    func save(_ metadata: RadioStationMetadata, generation: UInt64) async {
        await enqueue(.save(metadata, generation: generation))
    }

    func delete(recordName: String, generation: UInt64) async {
        await enqueue(.delete(recordName, generation: generation))
    }

    private func enqueue(_ operation: Operation) async {
        await withCheckedContinuation { continuation in
            latestGeneration[operation.recordName] = max(
                latestGeneration[operation.recordName, default: 0],
                operation.generation
            )
            pending.append(Request(operation: operation, continuation: continuation))
            guard !isDraining else { return }
            isDraining = true
            Task { [weak self] in
                await self?.drain()
            }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let request = pending.removeFirst()
            guard request.operation.generation == latestGeneration[request.operation.recordName] else {
                request.continuation.resume()
                continue
            }
            switch request.operation {
            case .save(let metadata, _):
                await CloudKitSyncService.shared.saveRadioMetadata(metadata)
            case .delete(let recordName, _):
                await CloudKitSyncService.shared.deleteRadioMetadata(recordName: recordName)
            }
            request.continuation.resume()
        }
        isDraining = false
    }
}

@MainActor
final class RadioStationStore: ObservableObject {
    static let shared = RadioStationStore()

    @Published private(set) var items: [RadioStationDisplayItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let api = SubsonicAPIService.shared
    private var refreshGeneration = 0
    private var metadataMutationRevision: UInt64 = 0
    private var metadataCloudGenerations: [String: UInt64] = [:]
    private var stationCoverPrewarmTask: Task<Void, Never>?
    /// Server scope of the currently published items. An empty list is scoped too,
    /// so a failed refresh can never leave another server's stations visible.
    private var itemsServerID: String?

    private init() {}

    private var selectedServer: SubsonicServer? {
        api.activeServer ?? ServerStore.shared.activeServer
    }

    /// Remote identity used for Cloud-synced station metadata.
    var activeServerId: String? {
        guard let server = selectedServer else { return nil }
        return server.stableId.isEmpty ? server.id.uuidString : server.stableId
    }

    /// Local configuration identity used for station-list cache ownership.
    /// Two configurations may intentionally point at the same remote user.
    private var activeServerConfigurationID: String? {
        selectedServer?.id.uuidString
    }

    func resetInMemory() {
        refreshGeneration += 1
        stationCoverPrewarmTask?.cancel()
        stationCoverPrewarmTask = nil
        replaceItems([], serverID: nil)
        isLoading = false
        errorMessage = nil
    }

    func refresh(waitForCloudMetadata: Bool = true) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        guard let configurationID = activeServerConfigurationID,
              let metadataServerID = activeServerId else {
            replaceItems([], serverID: nil)
            isLoading = false
            errorMessage = String(localized: "no_server_configured")
            return
        }

        await publishCachedStationsIfNeeded(
            configurationID: configurationID,
            metadataServerID: metadataServerID,
            generation: generation
        )

        isLoading = true
        defer {
            if refreshGeneration == generation {
                isLoading = false
            }
        }

        do {
            let stations = try await api.getInternetRadioStations()
            if let cacheError = await Self.saveCachedStations(stations, serverId: configurationID) {
                errorMessage = cacheError
            }

            let localMetadata = await filteredLocalMetadata(for: stations, serverId: metadataServerID)
            guard refreshGeneration == generation,
                  activeServerConfigurationID == configurationID,
                  activeServerId == metadataServerID else { return }
            replaceItems(
                displayItems(for: stations, serverId: metadataServerID, metadataByRecordName: localMetadata),
                serverID: configurationID
            )
            errorMessage = nil

            if waitForCloudMetadata {
                await applyMergedMetadata(
                    for: stations,
                    configurationID: configurationID,
                    metadataServerID: metadataServerID,
                    generation: generation
                )
            } else {
                Task { @MainActor [weak self] in
                    await self?.applyMergedMetadata(
                        for: stations,
                        configurationID: configurationID,
                        metadataServerID: metadataServerID,
                        generation: generation
                    )
                }
            }
        } catch {
            guard refreshGeneration == generation,
                  activeServerConfigurationID == configurationID,
                  activeServerId == metadataServerID else { return }
            if !(error is CancellationError) {
                publishError(error, onlyWhenItemsEmpty: true)
            }
        }
    }

    func createStation(
        name: String,
        streamURL: String,
        useAzuraCastAPI: Bool,
        azuraCastAPIURL: String,
        showSongCover: Bool
    ) async -> Bool {
        guard let operationConfigurationID = activeServerConfigurationID,
              let operationMetadataServerID = activeServerId else { return false }
        do {
            let normalized = try validate(name: name, streamURL: streamURL)
            try await api.createInternetRadioStation(name: normalized.name, streamURL: normalized.streamURL)
            guard matchesCurrentServerContext(
                configurationID: operationConfigurationID,
                metadataServerID: operationMetadataServerID
            ) else { return true }
            await refresh()
            guard matchesCurrentServerContext(
                configurationID: operationConfigurationID,
                metadataServerID: operationMetadataServerID
            ) else { return true }
            if let created = items.first(where: {
                RadioStationMetadata.normalizedStreamURL($0.streamURL) == RadioStationMetadata.normalizedStreamURL(normalized.streamURL)
            }) {
                var metadata = RadioStationMetadata(serverId: operationMetadataServerID, station: created.station)
                metadata.useAzuraCastAPI = useAzuraCastAPI
                metadata.azuraCastAPIURL = azuraCastAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
                metadata.showSongCover = showSongCover
                metadata.updatedAt = Date().timeIntervalSince1970
                let applyGeneration = refreshGeneration
                await saveMetadata(metadata)
                guard refreshGeneration == applyGeneration,
                      matchesCurrentServerContext(
                        configurationID: operationConfigurationID,
                        metadataServerID: operationMetadataServerID
                      ) else { return true }
                applyMetadata(metadata, to: created.id)
            }
            errorMessage = nil
            return true
        } catch {
            if !(error is CancellationError) {
                publishError(error, userInitiated: true)
            }
            return false
        }
    }

    func updateStation(
        _ item: RadioStationDisplayItem,
        name: String,
        streamURL: String,
        useAzuraCastAPI: Bool,
        azuraCastAPIURL: String,
        showSongCover: Bool
    ) async -> Bool {
        guard let operationConfigurationID = activeServerConfigurationID,
              let operationMetadataServerID = activeServerId else { return false }
        guard item.metadata.serverId.isEmpty
            || item.metadata.serverId == operationMetadataServerID else { return false }
        do {
            let normalized = try validate(name: name, streamURL: streamURL)
            try await api.updateInternetRadioStation(
                id: item.station.id,
                name: normalized.name,
                streamURL: normalized.streamURL
            )
            guard matchesCurrentServerContext(
                configurationID: operationConfigurationID,
                metadataServerID: operationMetadataServerID
            ) else { return true }
            var metadata = RadioStationMetadata(
                recordName: item.metadata.recordName,
                serverId: item.metadata.serverId,
                stationId: item.station.id,
                streamURLKey: RadioStationMetadata.normalizedStreamURL(normalized.streamURL),
                useAzuraCastAPI: useAzuraCastAPI,
                azuraCastAPIURL: azuraCastAPIURL.trimmingCharacters(in: .whitespacesAndNewlines),
                showSongCover: showSongCover,
                updatedAt: Date().timeIntervalSince1970
            )
            if metadata.serverId.isEmpty, let serverId = activeServerId {
                metadata = RadioStationMetadata(
                    recordName: RadioStationMetadata.recordName(serverId: serverId, stationId: item.station.id, streamURL: normalized.streamURL),
                    serverId: serverId,
                    stationId: item.station.id,
                    streamURLKey: RadioStationMetadata.normalizedStreamURL(normalized.streamURL),
                    useAzuraCastAPI: metadata.useAzuraCastAPI,
                    azuraCastAPIURL: metadata.azuraCastAPIURL,
                    showSongCover: metadata.showSongCover,
                    updatedAt: metadata.updatedAt
                )
            }
            await saveMetadata(metadata)
            guard matchesCurrentServerContext(
                configurationID: operationConfigurationID,
                metadataServerID: operationMetadataServerID
            ) else { return true }
            await refresh()
            guard matchesCurrentServerContext(
                configurationID: operationConfigurationID,
                metadataServerID: operationMetadataServerID
            ) else { return true }
            errorMessage = nil
            return true
        } catch {
            if !(error is CancellationError) {
                publishError(error, userInitiated: true)
            }
            return false
        }
    }

    func deleteStation(_ item: RadioStationDisplayItem) async -> Bool {
        guard let operationConfigurationID = activeServerConfigurationID,
              let operationMetadataServerID = activeServerId else { return false }
        guard item.metadata.serverId.isEmpty
            || item.metadata.serverId == operationMetadataServerID else { return false }
        do {
            try await api.deleteInternetRadioStation(id: item.station.id)
            guard matchesCurrentServerContext(
                configurationID: operationConfigurationID,
                metadataServerID: operationMetadataServerID
            ) else { return true }
            await deleteMetadata(item.metadata)
            guard matchesCurrentServerContext(
                configurationID: operationConfigurationID,
                metadataServerID: operationMetadataServerID
            ) else { return true }
            if AudioPlayerService.shared.currentRadioStation?.id == item.id {
                AudioPlayerService.shared.stop()
            }
            await refresh()
            guard matchesCurrentServerContext(
                configurationID: operationConfigurationID,
                metadataServerID: operationMetadataServerID
            ) else { return true }
            errorMessage = nil
            return true
        } catch {
            if !(error is CancellationError) {
                publishError(error, userInitiated: true)
            }
            return false
        }
    }

    func updateMetadata(for item: RadioStationDisplayItem, _ update: (inout RadioStationMetadata) -> Void) async {
        guard let operationConfigurationID = activeServerConfigurationID,
              let operationMetadataServerID = activeServerId else { return }
        guard item.metadata.serverId.isEmpty
            || item.metadata.serverId == operationMetadataServerID else { return }
        let operationGeneration = refreshGeneration
        var metadata = item.metadata
        update(&metadata)
        metadata.updatedAt = Date().timeIntervalSince1970
        await saveMetadata(metadata)
        guard refreshGeneration == operationGeneration,
              matchesCurrentServerContext(
                configurationID: operationConfigurationID,
                metadataServerID: operationMetadataServerID
              ) else { return }
        if let index = items.firstIndex(where: {
            $0.id == item.id && $0.metadata.recordName == metadata.recordName
        }) {
            items[index].metadata = metadata
        }
    }

    private func validate(name: String, streamURL: String) throws -> (name: String, streamURL: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SubsonicAPIError.apiError(0, String(localized: "radio_station_name_required"))
        }

        let trimmedURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            throw SubsonicAPIError.apiError(0, String(localized: "invalid_stream_url"))
        }

        return (trimmedName, trimmedURL)
    }

    private func mergedMetadata(
        for stations: [RadioStation],
        configurationID: String,
        serverId: String,
        generation: Int
    ) async -> [String: RadioStationMetadata]? {
        let mutationRevision = metadataMutationRevision
        let cacheURL = Self.metadataFileURL(serverId: serverId)
        let startingSnapshot = await RadioStationMetadataDiskCache.shared.snapshot(from: cacheURL)
        let recordNames = stations.map {
            RadioStationMetadata.recordName(serverId: serverId, stationId: $0.id, streamURL: $0.streamURL)
        }
        guard !recordNames.isEmpty else {
            guard isCurrentRefresh(
                generation: generation,
                configurationID: configurationID,
                metadataServerID: serverId,
                mutationRevision: mutationRevision
            ) else { return nil }
            let cleared = await RadioStationMetadataDiskCache.shared.replaceIfUnchanged(
                [],
                expectedRevision: startingSnapshot.revision,
                at: cacheURL
            )
            guard cleared != nil,
                  isCurrentRefresh(
                    generation: generation,
                    configurationID: configurationID,
                    metadataServerID: serverId,
                    mutationRevision: mutationRevision
                  ) else { return nil }
            return [:]
        }

        let remote = await CloudKitSyncService.shared.fetchRadioMetadata(recordNames: recordNames)
        guard isCurrentRefresh(
            generation: generation,
            configurationID: configurationID,
            metadataServerID: serverId,
            mutationRevision: mutationRevision
        ) else { return nil }
        let remoteByRecordName = Dictionary(uniqueKeysWithValues: remote.map { ($0.recordName, $0) })
        let validRecords = Set(recordNames)
        guard let merged = await RadioStationMetadataDiskCache.shared.merge(
            remote: remote,
            validRecordNames: validRecords,
            expectedRevision: startingSnapshot.revision,
            at: cacheURL
        ) else { return nil }
        guard isCurrentRefresh(
            generation: generation,
            configurationID: configurationID,
            metadataServerID: serverId,
            mutationRevision: mutationRevision
        ) else { return nil }
        for metadata in merged.metadata.values where shouldUploadLocalMetadata(metadata, remote: remoteByRecordName[metadata.recordName]) {
            guard await RadioStationMetadataDiskCache.shared.revision(at: cacheURL) == merged.revision,
                  isCurrentRefresh(
                    generation: generation,
                    configurationID: configurationID,
                    metadataServerID: serverId,
                    mutationRevision: mutationRevision
                  ) else { return nil }
            let cloudGeneration = metadataCloudGenerations[metadata.recordName, default: 0]
            await RadioStationMetadataCloudWriter.shared.save(
                metadata,
                generation: cloudGeneration
            )
            guard await RadioStationMetadataDiskCache.shared.revision(at: cacheURL) == merged.revision,
                  isCurrentRefresh(
                    generation: generation,
                    configurationID: configurationID,
                    metadataServerID: serverId,
                    mutationRevision: mutationRevision
                  ) else { return nil }
        }
        // A user edit may have arrived while the uploads above were suspended.
        // Re-read once so the UI can never be replaced with the older merge snapshot.
        let latest = await Self.loadLocalMetadata(serverId: serverId)
            .filter { validRecords.contains($0.key) }
        guard isCurrentRefresh(
            generation: generation,
            configurationID: configurationID,
            metadataServerID: serverId,
            mutationRevision: mutationRevision
        ) else { return nil }
        return latest
    }

    private func applyMergedMetadata(
        for stations: [RadioStation],
        configurationID: String,
        metadataServerID: String,
        generation: Int
    ) async {
        guard let mergedMetadata = await mergedMetadata(
            for: stations,
            configurationID: configurationID,
            serverId: metadataServerID,
            generation: generation
        ) else { return }
        guard refreshGeneration == generation,
              activeServerConfigurationID == configurationID,
              activeServerId == metadataServerID else { return }
        replaceItems(
            displayItems(for: stations, serverId: metadataServerID, metadataByRecordName: mergedMetadata),
            serverID: configurationID
        )
        errorMessage = nil
    }

    private func shouldUploadLocalMetadata(_ local: RadioStationMetadata, remote: RadioStationMetadata?) -> Bool {
        if let remote {
            return local.updatedAt > remote.updatedAt
        }
        return local.useAzuraCastAPI
            || !local.azuraCastAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || local.showSongCover == false
    }

    private func isCurrentRefresh(
        generation: Int,
        configurationID: String,
        metadataServerID: String,
        mutationRevision: UInt64
    ) -> Bool {
        refreshGeneration == generation
            && activeServerConfigurationID == configurationID
            && activeServerId == metadataServerID
            && metadataMutationRevision == mutationRevision
    }

    private func matchesCurrentServerContext(
        configurationID: String,
        metadataServerID: String
    ) -> Bool {
        activeServerConfigurationID == configurationID
            && activeServerId == metadataServerID
            && itemsServerID == configurationID
    }

    private func orderedItems(_ items: [RadioStationDisplayItem]) -> [RadioStationDisplayItem] {
        items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func publishCachedStationsIfNeeded(
        configurationID: String,
        metadataServerID: String,
        generation: Int
    ) async {
        guard itemsServerID != configurationID || items.isEmpty else { return }
        let stations = await Self.loadCachedStations(serverId: configurationID)
        let metadata = await filteredLocalMetadata(for: stations, serverId: metadataServerID)
        guard refreshGeneration == generation,
              activeServerConfigurationID == configurationID,
              activeServerId == metadataServerID else { return }
        replaceItems(
            displayItems(for: stations, serverId: metadataServerID, metadataByRecordName: metadata),
            serverID: configurationID
        )
        errorMessage = nil
    }

    private func displayItems(
        for stations: [RadioStation],
        serverId: String,
        metadataByRecordName: [String: RadioStationMetadata]
    ) -> [RadioStationDisplayItem] {
        orderedItems(stations.map { station in
            let recordName = RadioStationMetadata.recordName(
                serverId: serverId,
                stationId: station.id,
                streamURL: station.streamURL
            )
            let metadata = metadataByRecordName[recordName] ?? RadioStationMetadata(serverId: serverId, station: station)
            return RadioStationDisplayItem(station: station, metadata: metadata)
        })
    }

    private func filteredLocalMetadata(for stations: [RadioStation], serverId: String) async -> [String: RadioStationMetadata] {
        let validRecords = Set(stations.map {
            RadioStationMetadata.recordName(serverId: serverId, stationId: $0.id, streamURL: $0.streamURL)
        })
        guard !validRecords.isEmpty else { return [:] }
        return await Self.loadLocalMetadata(serverId: serverId).filter { validRecords.contains($0.key) }
    }

    private func applyMetadata(_ metadata: RadioStationMetadata, to itemId: String) {
        guard activeServerId == metadata.serverId,
              let index = items.firstIndex(where: {
                $0.id == itemId && $0.metadata.recordName == metadata.recordName
              }) else { return }
        items[index].metadata = metadata
        setItems(orderedItems(items))
    }

    private func setItems(_ newItems: [RadioStationDisplayItem]) {
        items = newItems
        if let currentID = AudioPlayerService.shared.currentRadioStation?.id,
           let resolved = newItems.first(where: { $0.id == currentID }) {
            AudioPlayerService.shared.adoptResolvedRadioConfiguration(resolved)
        }
        AudioPlayerService.shared.updateRemoteCommandAvailability()
        prewarmStationCovers(for: newItems)
    }

    private func replaceItems(_ newItems: [RadioStationDisplayItem], serverID: String?) {
        itemsServerID = serverID
        setItems(newItems)
    }

    private func prewarmStationCovers(for items: [RadioStationDisplayItem]) {
        stationCoverPrewarmTask?.cancel()

        var seen = Set<String>()
        let coverArtIDs = items.compactMap(\.coverArt).filter { seen.insert($0).inserted }
        guard !coverArtIDs.isEmpty, !OfflineModeService.shared.isOffline else {
            stationCoverPrewarmTask = nil
            return
        }

        stationCoverPrewarmTask = Task.detached(priority: .utility) {
            await Self.prewarmStationCoverArtIDs(coverArtIDs)
        }
    }

    private nonisolated static func prewarmStationCoverArtIDs(_ coverArtIDs: [String]) async {
        let chunks = stride(from: 0, to: coverArtIDs.count, by: 4).map {
            Array(coverArtIDs[$0..<min($0 + 4, coverArtIDs.count)])
        }

        for chunk in chunks {
            if Task.isCancelled { return }
            await withTaskGroup(of: Void.self) { group in
                for coverArtID in chunk {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        await prewarmStationCoverArt(coverArtID)
                    }
                }
            }
        }
    }

    private nonisolated static func prewarmStationCoverArt(_ coverArtID: String) async {
        #if DEBUG
        guard !coverArtID.hasPrefix("demo_") else { return }
        #endif
        guard let url = SubsonicAPIService.shared.coverArtURL(for: coverArtID, size: 600) else { return }
        #if os(iOS)
        _ = await ImageCacheService.shared.image(url: url, key: "\(coverArtID)_600")
        #else
        _ = await ImageCacheService.shared.image(url: url)
        #endif
    }

    private func saveMetadata(_ metadata: RadioStationMetadata) async {
        metadataMutationRevision &+= 1
        let cloudGeneration = nextMetadataCloudGeneration(for: metadata.recordName)
        let url = Self.metadataFileURL(serverId: metadata.serverId)
        if let cacheError = await RadioStationMetadataDiskCache.shared.upsert(metadata, at: url) {
            errorMessage = cacheError
        }
        await RadioStationMetadataCloudWriter.shared.save(
            metadata,
            generation: cloudGeneration
        )
    }

    private func deleteMetadata(_ metadata: RadioStationMetadata) async {
        metadataMutationRevision &+= 1
        let cloudGeneration = nextMetadataCloudGeneration(for: metadata.recordName)
        let url = Self.metadataFileURL(serverId: metadata.serverId)
        if let cacheError = await RadioStationMetadataDiskCache.shared.remove(recordName: metadata.recordName, at: url) {
            errorMessage = cacheError
        }
        await RadioStationMetadataCloudWriter.shared.delete(
            recordName: metadata.recordName,
            generation: cloudGeneration
        )
    }

    private func nextMetadataCloudGeneration(for recordName: String) -> UInt64 {
        let generation = metadataCloudGenerations[recordName, default: 0] &+ 1
        metadataCloudGenerations[recordName] = generation
        return generation
    }

    private nonisolated static func loadLocalMetadata(serverId: String) async -> [String: RadioStationMetadata] {
        await RadioStationMetadataDiskCache.shared.load(from: metadataFileURL(serverId: serverId))
    }

    private nonisolated static func loadCachedStations(serverId: String) async -> [RadioStation] {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: stationCacheFileURL(serverId: serverId)),
                  let stations = try? JSONDecoder().decode([RadioStation].self, from: data)
            else { return [] }
            return stations
        }.value
    }

    private nonisolated static func saveCachedStations(_ stations: [RadioStation], serverId: String) async -> String? {
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(stations) else { return nil }
            let url = stationCacheFileURL(serverId: serverId)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    private nonisolated static func metadataFileURL(serverId: String) -> URL {
        let safeServerId = serverId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "server"
        return radioRootDirectoryURL()
            .appendingPathComponent("\(safeServerId).json")
    }

    private nonisolated static func stationCacheFileURL(serverId: String) -> URL {
        let safeServerId = serverId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "server"
        return radioRootDirectoryURL()
            .appendingPathComponent("\(safeServerId).stations.json")
    }

    private nonisolated static func radioRootDirectoryURL() -> URL {
        #if os(tvOS)
        let baseDirectory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let baseDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return baseDirectory
            .appendingPathComponent("Shelv", isDirectory: true)
            .appendingPathComponent("Radio", isDirectory: true)
    }

    private func radioErrorDescription(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return error.localizedDescription
    }

    private func publishError(
        _ error: Error,
        onlyWhenItemsEmpty: Bool = false,
        userInitiated: Bool = false
    ) {
        if OfflineModeService.shared.presentConnectivityErrorIfNeeded(
            error,
            userInitiated: userInitiated
        ) {
            errorMessage = nil
        } else {
            errorMessage = onlyWhenItemsEmpty && !items.isEmpty
                ? nil
                : radioErrorDescription(error)
        }
    }
}
