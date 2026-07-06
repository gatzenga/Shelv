import CarPlay
import Combine
import UIKit

@MainActor
final class CarPlayRadioController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var coverTask: Task<Void, Never>?
    private var stationItemsByID: [String: CPListItem] = [:]
    private var stationOrder: [String] = []
    private var stationCoverArtByID: [String: String] = [:]
    private var stationImagesByID: [String: UIImage] = [:]
    private var isShowingStations = false
    private var coverLoadGeneration = 0

    private static let radioPlaceholder = UIImage(systemName: "radio")

    private struct CoverTarget {
        let stationID: String
        let coverArt: String
        let item: CPListItem
    }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let template = CPListTemplate(title: String(localized: "radio"), sections: [])
        template.tabImage = UIImage(systemName: "dot.radiowaves.left.and.right")
        rootTemplate = template
    }

    func load() {
        RadioStationStore.shared.$items
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        RadioStationStore.shared.$isLoading
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        RadioStationStore.shared.$errorMessage
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        OfflineModeService.shared.$isOffline
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        reload()
    }

    func cancel() {
        loadTask?.cancel()
        coverTask?.cancel()
        cancellables.removeAll()
        stationItemsByID.removeAll()
        stationOrder.removeAll()
        stationCoverArtByID.removeAll()
        stationImagesByID.removeAll()
        isShowingStations = false
        coverLoadGeneration += 1
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            if OfflineModeService.shared.isOffline {
                rebuild()
                return
            }
            await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            rebuild()
        }
    }

    private func rebuild() {
        coverTask?.cancel()
        coverLoadGeneration += 1
        let generation = coverLoadGeneration

        if OfflineModeService.shared.isOffline {
            isShowingStations = false
            let item = CPListItem(text: String(localized: "not_available_offline"), detailText: nil)
            item.setImage(cpListIcon("wifi.slash"))
            rootTemplate.updateSections([CPListSection(items: [item])])
            return
        }

        let store = RadioStationStore.shared
        if store.isLoading && store.items.isEmpty {
            isShowingStations = false
            let item = CPListItem(text: String(localized: "loading"), detailText: nil)
            item.setImage(cpListIcon("arrow.clockwise"))
            rootTemplate.updateSections([CPListSection(items: [item])])
            return
        }

        if let message = store.errorMessage, store.items.isEmpty {
            isShowingStations = false
            let item = CPListItem(text: String(localized: "error"), detailText: message)
            item.setImage(cpListIcon("exclamationmark.triangle"))
            rootTemplate.updateSections([CPListSection(items: [item, makeRefreshItem()])])
            return
        }

        guard !store.items.isEmpty else {
            isShowingStations = false
            let item = CPListItem(text: String(localized: "no_radio_stations"), detailText: nil)
            item.setImage(cpListIcon("dot.radiowaves.left.and.right"))
            rootTemplate.updateSections([CPListSection(items: [item, makeRefreshItem()])])
            return
        }

        let oldOrder = stationOrder
        let built = buildStationItems(store.items)
        if !isShowingStations || oldOrder != stationOrder {
            rootTemplate.updateSections([CPListSection(items: built.items, header: nil, sectionIndexTitle: nil)])
        }
        isShowingStations = true
        guard !built.coverTargets.isEmpty else { return }
        coverTask = Task { @MainActor in
            await loadStationCovers(built.coverTargets, generation: generation)
        }
    }

    private func makeRefreshItem() -> CPListItem {
        actionListItem(title: String(localized: "refresh"), systemImage: "arrow.clockwise") { [weak self] _, completion in
            self?.manualRefresh(completion: completion) ?? completion()
        }
    }

    private func manualRefresh(completion: @escaping () -> Void) {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else {
                completion()
                return
            }
            if await OfflineModeService.shared.beginUserInitiatedServerRefresh() {
                completion()
                return
            }
            defer { OfflineModeService.shared.finishUserInitiatedServerRefresh() }
            _ = await NetworkStatus.shared.waitUntilNetworkAvailable()
            await RadioStationStore.shared.refresh(waitForCloudMetadata: false)
            guard !Task.isCancelled else {
                completion()
                return
            }
            self.rebuild()
            completion()
        }
    }

    private func buildStationItems(_ stations: [RadioStationDisplayItem]) -> (items: [CPListItem], coverTargets: [CoverTarget]) {
        var newOrder: [String] = []
        newOrder.reserveCapacity(stations.count)
        var coverTargets: [CoverTarget] = []
        var aliveIDs = Set<String>()

        let items = stations.map { station -> CPListItem in
            aliveIDs.insert(station.id)
            newOrder.append(station.id)

            let item: CPListItem
            let coverArtChanged = stationCoverArtByID[station.id] != station.coverArt
            let isNewItem: Bool
            if let existing = stationItemsByID[station.id] {
                existing.setText(station.name)
                item = existing
                isNewItem = false
            } else {
                item = CPListItem(text: station.name, detailText: nil, image: Self.radioPlaceholder)
                stationItemsByID[station.id] = item
                isNewItem = true
            }

            if let coverArt = station.coverArt {
                if let image = stationImagesByID[station.id], !coverArtChanged {
                    item.setImage(image)
                } else if let cached = cachedStationCover(coverArt) {
                    stationImagesByID[station.id] = cached
                    item.setImage(cached)
                } else if isNewItem || coverArtChanged {
                    item.setImage(cpPlaceholder)
                }
                coverTargets.append(CoverTarget(stationID: station.id, coverArt: coverArt, item: item))
            } else {
                item.setImage(Self.radioPlaceholder)
                stationImagesByID.removeValue(forKey: station.id)
            }
            item.handler = { [weak self] _, completion in
                AudioPlayerService.shared.playRadioStation(station)
                if let self {
                    CarPlayNavigation.presentNowPlaying(on: self.interfaceController)
                }
                completion()
            }
            if let coverArt = station.coverArt {
                stationCoverArtByID[station.id] = coverArt
            } else {
                stationCoverArtByID.removeValue(forKey: station.id)
            }
            return item
        }

        for id in stationItemsByID.keys where !aliveIDs.contains(id) {
            stationItemsByID.removeValue(forKey: id)
            stationCoverArtByID.removeValue(forKey: id)
            stationImagesByID.removeValue(forKey: id)
        }
        stationOrder = newOrder
        return (items, coverTargets)
    }

    private func cachedStationCover(_ coverArt: String) -> UIImage? {
        for size in [300, 600, 150, 120, 100, 80, 50] {
            if let image = ImageCacheService.shared.cachedImage(key: "\(coverArt)_\(size)") {
                return squareCropped(image)
            }
        }
        return nil
    }

    private func loadStationCovers(_ targets: [CoverTarget], generation: Int) async {
        var targetsByCoverArt: [String: [CoverTarget]] = [:]
        for target in targets {
            targetsByCoverArt[target.coverArt, default: []].append(target)
        }
        let coverArtIds = Array(targetsByCoverArt.keys).map(Optional.some)
        await loadCoversIncremental(coverArtIds: coverArtIds, size: 300, chunkSize: 8) { [weak self] chunk in
            guard let self, self.coverLoadGeneration == generation else { return }
            for (coverArt, image) in chunk {
                guard let targets = targetsByCoverArt[coverArt] else { continue }
                let cover = squareCropped(image)
                for target in targets {
                    guard self.stationCoverArtByID[target.stationID] == coverArt else { continue }
                    self.stationImagesByID[target.stationID] = cover
                    target.item.setImage(cover)
                }
            }
        }
    }
}
