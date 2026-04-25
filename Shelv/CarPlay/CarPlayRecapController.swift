import CarPlay
import Combine

@MainActor
final class CarPlayRecapController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var cancellables = Set<AnyCancellable>()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let t = CPListTemplate(title: tr("Recap", "Recap"), sections: [])
        t.tabImage = UIImage(systemName: "calendar.badge.clock")
        rootTemplate = t
    }

    func load() {
        RecapStore.shared.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        LibraryStore.shared.$playlists
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        DownloadStore.shared.$offlinePlaylistIds
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard OfflineModeService.shared.isOffline else { return }
                self?.rebuild()
            }
            .store(in: &cancellables)

        OfflineModeService.shared.$isOffline
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        rebuild()
    }

    func cancel() {
        cancellables.removeAll()
    }

    private func rebuild() {
        let entries = visibleEntries()
        if entries.isEmpty {
            let empty = CPListItem(
                text: OfflineModeService.shared.isOffline
                    ? tr("No offline recaps", "Keine Offline-Recaps")
                    : tr("No recaps", "Keine Recaps"),
                detailText: nil
            )
            rootTemplate.updateSections([CPListSection(items: [empty])])
            return
        }

        let items = entries.map { entry -> CPListItem in
            recapListItem(entry) { [weak self] _, c in
                guard let self else { c(); return }
                self.openRecap(entry)
                c()
            }
        }
        rootTemplate.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
    }

    private func visibleEntries() -> [RecapRegistryRecord] {
        let all = RecapStore.shared.entries
        guard OfflineModeService.shared.isOffline else { return all }
        let downloaded = DownloadStore.shared.offlinePlaylistIds
        return all.filter { downloaded.contains($0.playlistId) }
    }

    private func recapListItem(_ entry: RecapRegistryRecord, handler: @escaping CPItemHandler) -> CPListItem {
        let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
        let period = RecapPeriod(
            type: type,
            start: Date(timeIntervalSince1970: entry.periodStart),
            end:   Date(timeIntervalSince1970: entry.periodEnd)
        )
        let item = CPListItem(text: period.playlistName, detailText: nil)
        item.setImage(cpIcon(type.icon, pointSize: 36))
        item.accessoryType = .disclosureIndicator
        item.handler = handler
        return item
    }

    private func openRecap(_ entry: RecapRegistryRecord) {
        // Bevorzugt das Playlist-Objekt aus dem LibraryStore — dort sind Cover, Songs etc. korrekt.
        // Fallback: synthetisches Objekt damit der Detail-Push trotzdem funktioniert.
        let fallbackName: String = {
            let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
            let period = RecapPeriod(
                type: type,
                start: Date(timeIntervalSince1970: entry.periodStart),
                end:   Date(timeIntervalSince1970: entry.periodEnd)
            )
            return period.playlistName
        }()
        let playlist = LibraryStore.shared.playlists.first { $0.id == entry.playlistId }
            ?? Playlist(
                id: entry.playlistId,
                name: fallbackName,
                comment: nil, songCount: nil, duration: nil, coverArt: nil
            )
        CarPlayNavigation.openPlaylist(playlist, from: interfaceController)
    }
}
