import CarPlay
import Combine

@MainActor
final class CarPlayRecapController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var cancellables = Set<AnyCancellable>()
    private weak var weeklyTemplate: CPListTemplate?
    private weak var monthlyTemplate: CPListTemplate?
    private weak var yearlyTemplate: CPListTemplate?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let t = CPListTemplate(title: String(localized: "recap"), sections: [])
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
                    ? String(localized: "no_offline_recaps")
                    : String(localized: "no_recaps"),
                detailText: nil
            )
            rootTemplate.updateSections([CPListSection(items: [empty])])
            rebuildOpenPeriodTemplates()
            return
        }

        let items = periodTypes.map { type in
            menuListItem(title: type.label, systemImage: type.icon) { [weak self] _, completion in
                completion()
                self?.pushRecaps(for: type)
            }
        }
        rootTemplate.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
        rebuildOpenPeriodTemplates()
    }

    /// Gleiche Reihenfolge wie im Recap-Picker auf dem iPhone.
    private var periodTypes: [RecapPeriod.PeriodType] {
        [.week, .month, .year]
    }

    private func visibleEntries() -> [RecapRegistryRecord] {
        let all = RecapStore.shared.entries
        guard OfflineModeService.shared.isOffline else { return all }
        let downloaded = DownloadStore.shared.offlinePlaylistIds
        return all.filter { downloaded.contains($0.playlistId) }
    }

    private func entries(for type: RecapPeriod.PeriodType) -> [RecapRegistryRecord] {
        visibleEntries()
            .filter { $0.periodType == type.rawValue }
            .sorted { $0.periodStart > $1.periodStart }
    }

    private func pushRecaps(for type: RecapPeriod.PeriodType) {
        let template = CPListTemplate(title: type.label, sections: sections(for: type))
        setOpenTemplate(template, for: type)
        CarPlayNavigation.safePush(template, on: interfaceController)
    }

    private func sections(for type: RecapPeriod.PeriodType) -> [CPListSection] {
        let entries = entries(for: type)
        guard !entries.isEmpty else {
            let message = OfflineModeService.shared.isOffline
                ? String(localized: "no_offline_recaps")
                : String(localized: "no_recap_generated_yet_for_this_period")
            return [CPListSection(items: [CPListItem(text: message, detailText: nil)])]
        }

        let items = entries.map { entry in
            recapListItem(entry) { [weak self] _, completion in
                completion()
                self?.openRecap(entry)
            }
        }
        return [CPListSection(items: items, header: nil, sectionIndexTitle: nil)]
    }

    private func rebuildOpenPeriodTemplates() {
        weeklyTemplate?.updateSections(sections(for: .week))
        monthlyTemplate?.updateSections(sections(for: .month))
        yearlyTemplate?.updateSections(sections(for: .year))
    }

    private func setOpenTemplate(_ template: CPListTemplate, for type: RecapPeriod.PeriodType) {
        switch type {
        case .week:  weeklyTemplate = template
        case .month: monthlyTemplate = template
        case .year:  yearlyTemplate = template
        }
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
