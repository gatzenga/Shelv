import Combine
import Foundation

@MainActor
final class RadioStationStore: ObservableObject {
    static let shared = RadioStationStore()

    @Published private(set) var items: [RadioStationDisplayItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let api = SubsonicAPIService.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var refreshGeneration = 0
    private var stationCoverPrewarmTask: Task<Void, Never>?

    private init() {}

    var activeServerId: String? {
        guard let server = api.activeServer else { return nil }
        return server.stableId.isEmpty ? server.id.uuidString : server.stableId
    }

    func resetInMemory() {
        refreshGeneration += 1
        stationCoverPrewarmTask?.cancel()
        stationCoverPrewarmTask = nil
        setItems([])
        isLoading = false
        errorMessage = nil
    }

    func refresh(waitForCloudMetadata: Bool = true) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        guard let serverId = activeServerId else {
            setItems([])
            isLoading = false
            errorMessage = String(localized: "no_server_configured")
            return
        }

        publishCachedStationsIfNeeded(serverId: serverId)

        isLoading = true
        defer {
            if refreshGeneration == generation {
                isLoading = false
            }
        }

        do {
            let stations = try await api.getInternetRadioStations()
            saveCachedStations(stations, serverId: serverId)

            let localMetadata = filteredLocalMetadata(for: stations, serverId: serverId)
            guard refreshGeneration == generation, activeServerId == serverId else { return }
            setItems(displayItems(for: stations, serverId: serverId, metadataByRecordName: localMetadata))
            errorMessage = nil

            if waitForCloudMetadata {
                await applyMergedMetadata(for: stations, serverId: serverId, generation: generation)
            } else {
                Task { @MainActor [weak self] in
                    await self?.applyMergedMetadata(for: stations, serverId: serverId, generation: generation)
                }
            }
        } catch {
            guard refreshGeneration == generation else { return }
            if !(error is CancellationError) {
                errorMessage = items.isEmpty ? radioErrorDescription(error) : nil
            }
        }
    }

    /// Makes the persisted station list available to App Entity suggestions
    /// without turning a cold Shortcuts picker into a network request.
    func publishShortcutCacheIfNeeded() {
        guard let serverId = activeServerId else { return }
        publishCachedStationsIfNeeded(serverId: serverId)
    }

    func createStation(
        name: String,
        streamURL: String,
        useAzuraCastAPI: Bool,
        azuraCastAPIURL: String,
        showSongCover: Bool
    ) async -> Bool {
        do {
            let normalized = try validate(name: name, streamURL: streamURL)
            try await api.createInternetRadioStation(name: normalized.name, streamURL: normalized.streamURL)
            await refresh()
            if let created = items.first(where: {
                RadioStationMetadata.normalizedStreamURL($0.streamURL) == RadioStationMetadata.normalizedStreamURL(normalized.streamURL)
            }) {
                var metadata = RadioStationMetadata(serverId: activeServerId ?? "", station: created.station)
                metadata.useAzuraCastAPI = useAzuraCastAPI
                metadata.azuraCastAPIURL = azuraCastAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
                metadata.showSongCover = showSongCover
                metadata.updatedAt = Date().timeIntervalSince1970
                await saveMetadata(metadata)
                applyMetadata(metadata, to: created.id)
            }
            errorMessage = nil
            return true
        } catch {
            if !(error is CancellationError) {
                errorMessage = radioErrorDescription(error)
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
        do {
            let normalized = try validate(name: name, streamURL: streamURL)
            try await api.updateInternetRadioStation(
                id: item.station.id,
                name: normalized.name,
                streamURL: normalized.streamURL
            )
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
            await refresh()
            errorMessage = nil
            return true
        } catch {
            if !(error is CancellationError) {
                errorMessage = radioErrorDescription(error)
            }
            return false
        }
    }

    func deleteStation(_ item: RadioStationDisplayItem) async -> Bool {
        do {
            try await api.deleteInternetRadioStation(id: item.station.id)
            await deleteMetadata(item.metadata)
            if AudioPlayerService.shared.currentRadioStation?.id == item.id {
                AudioPlayerService.shared.stop()
            }
            await refresh()
            errorMessage = nil
            return true
        } catch {
            if !(error is CancellationError) {
                errorMessage = radioErrorDescription(error)
            }
            return false
        }
    }

    func updateMetadata(for item: RadioStationDisplayItem, _ update: (inout RadioStationMetadata) -> Void) async {
        var metadata = item.metadata
        update(&metadata)
        metadata.updatedAt = Date().timeIntervalSince1970
        await saveMetadata(metadata)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
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

    private func mergedMetadata(for stations: [RadioStation], serverId: String) async -> [String: RadioStationMetadata] {
        let recordNames = stations.map {
            RadioStationMetadata.recordName(serverId: serverId, stationId: $0.id, streamURL: $0.streamURL)
        }
        guard !recordNames.isEmpty else {
            saveLocalMetadata([], serverId: serverId)
            return [:]
        }

        var local = loadLocalMetadata(serverId: serverId)
        let remote = await CloudKitSyncService.shared.fetchRadioMetadata(recordNames: recordNames)
        let remoteByRecordName = Dictionary(uniqueKeysWithValues: remote.map { ($0.recordName, $0) })

        for metadata in remote {
            if let existing = local[metadata.recordName], existing.updatedAt > metadata.updatedAt {
                continue
            }
            local[metadata.recordName] = metadata
        }

        let validRecords = Set(recordNames)
        local = local.filter { validRecords.contains($0.key) }
        saveLocalMetadata(Array(local.values), serverId: serverId)
        for metadata in local.values where shouldUploadLocalMetadata(metadata, remote: remoteByRecordName[metadata.recordName]) {
            await CloudKitSyncService.shared.saveRadioMetadata(metadata)
        }
        return local
    }

    private func applyMergedMetadata(for stations: [RadioStation], serverId: String, generation: Int) async {
        let mergedMetadata = await mergedMetadata(for: stations, serverId: serverId)
        guard refreshGeneration == generation, activeServerId == serverId else { return }
        setItems(displayItems(for: stations, serverId: serverId, metadataByRecordName: mergedMetadata))
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

    private func orderedItems(_ items: [RadioStationDisplayItem]) -> [RadioStationDisplayItem] {
        items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func publishCachedStationsIfNeeded(serverId: String) {
        guard items.isEmpty else { return }
        let stations = loadCachedStations(serverId: serverId)
        guard !stations.isEmpty else { return }
        let metadata = filteredLocalMetadata(for: stations, serverId: serverId)
        setItems(displayItems(for: stations, serverId: serverId, metadataByRecordName: metadata))
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

    private func filteredLocalMetadata(for stations: [RadioStation], serverId: String) -> [String: RadioStationMetadata] {
        let validRecords = Set(stations.map {
            RadioStationMetadata.recordName(serverId: serverId, stationId: $0.id, streamURL: $0.streamURL)
        })
        guard !validRecords.isEmpty else { return [:] }
        return loadLocalMetadata(serverId: serverId).filter { validRecords.contains($0.key) }
    }

    private func applyMetadata(_ metadata: RadioStationMetadata, to itemId: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
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
        var local = loadLocalMetadata(serverId: metadata.serverId)
        local[metadata.recordName] = metadata
        saveLocalMetadata(Array(local.values), serverId: metadata.serverId)
        await CloudKitSyncService.shared.saveRadioMetadata(metadata)
    }

    private func deleteMetadata(_ metadata: RadioStationMetadata) async {
        var local = loadLocalMetadata(serverId: metadata.serverId)
        local.removeValue(forKey: metadata.recordName)
        saveLocalMetadata(Array(local.values), serverId: metadata.serverId)
        await CloudKitSyncService.shared.deleteRadioMetadata(recordName: metadata.recordName)
    }

    private func loadLocalMetadata(serverId: String) -> [String: RadioStationMetadata] {
        guard let data = try? Data(contentsOf: metadataFileURL(serverId: serverId)),
              let metadata = try? decoder.decode([RadioStationMetadata].self, from: data)
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

    private func loadCachedStations(serverId: String) -> [RadioStation] {
        guard let data = try? Data(contentsOf: stationCacheFileURL(serverId: serverId)),
              let stations = try? decoder.decode([RadioStation].self, from: data)
        else { return [] }
        return stations
    }

    private func saveCachedStations(_ stations: [RadioStation], serverId: String) {
        guard let data = try? encoder.encode(stations) else { return }
        let url = stationCacheFileURL(serverId: serverId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveLocalMetadata(_ metadata: [RadioStationMetadata], serverId: String) {
        guard let data = try? encoder.encode(metadata) else { return }
        let url = metadataFileURL(serverId: serverId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func metadataFileURL(serverId: String) -> URL {
        let safeServerId = serverId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "server"
        return radioRootDirectoryURL()
            .appendingPathComponent("\(safeServerId).json")
    }

    private func stationCacheFileURL(serverId: String) -> URL {
        let safeServerId = serverId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "server"
        return radioRootDirectoryURL()
            .appendingPathComponent("\(safeServerId).stations.json")
    }

    private func radioRootDirectoryURL() -> URL {
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
}
