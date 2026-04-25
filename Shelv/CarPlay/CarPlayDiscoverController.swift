import CarPlay
import Combine

@MainActor
final class CarPlayDiscoverController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let t = CPListTemplate(title: tr("Discover", "Entdecken"), sections: [])
        t.tabImage = UIImage(systemName: "sparkles")
        rootTemplate = t
    }

    func load() {
        OfflineModeService.shared.$isOffline
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        LibraryStore.shared.$reloadID
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        reload()
    }

    func cancel() {
        loadTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Private

    private func reload() {
        loadTask?.cancel()
        if OfflineModeService.shared.isOffline {
            showOffline()
            return
        }
        loadTask = Task { await fetchAndBuild() }
    }

    private func showOffline() {
        let goOnline = CPListItem(text: tr("Go Online", "Online gehen"), detailText: nil)
        goOnline.handler = { _, c in
            Task { @MainActor in OfflineModeService.shared.exitOfflineMode() }
            c()
        }
        let section = CPListSection(
            items: [goOnline],
            header: tr("You are offline", "Du bist offline"),
            sectionIndexTitle: nil
        )
        rootTemplate.updateSections([section])
    }

    private func fetchAndBuild() async {
        await LibraryStore.shared.loadDiscover()
        guard !Task.isCancelled else { return }

        let allEmpty = LibraryStore.shared.recentlyAdded.isEmpty
            && LibraryStore.shared.recentlyPlayed.isEmpty
            && LibraryStore.shared.frequentlyPlayed.isEmpty
        if allEmpty, LibraryStore.shared.errorMessage != nil {
            showNoConnection()
            LibraryStore.shared.errorMessage = nil
            return
        }

        let sections = buildSections()
        rootTemplate.updateSections(sections)
        guard !Task.isCancelled else { return }
        await enrichWithCovers()
    }

    private func showNoConnection() {
        let enableOffline = CPListItem(text: tr("Enable Offline Mode", "Offline-Modus aktivieren"), detailText: nil)
        enableOffline.handler = { _, c in
            Task { @MainActor in OfflineModeService.shared.enterOfflineMode() }
            c()
        }
        let section = CPListSection(
            items: [enableOffline],
            header: tr("No connection", "Keine Verbindung"),
            sectionIndexTitle: nil
        )
        rootTemplate.updateSections([section])
    }

    private func buildSections(imageMap: [String: UIImage] = [:]) -> [CPListSection] {
        var sections: [CPListSection] = []

        let mixItems: [CPListItem] = [
            makeMixItem(tr("Mix: Newest Tracks", "Mix: Neueste Titel"), type: "newest"),
            makeMixItem(tr("Mix: Frequently Played", "Mix: Häufig gespielt"), type: "frequent"),
            makeMixItem(tr("Mix: Recently Played", "Mix: Kürzlich gespielt"), type: "recent"),
        ]
        sections.append(CPListSection(items: mixItems, header: "Mixes", sectionIndexTitle: nil))

        let categories: [(String, [Album])] = [
            (tr("Recently Added", "Zuletzt hinzugefügt"), LibraryStore.shared.recentlyAdded),
            (tr("Recently Played", "Zuletzt gespielt"),   LibraryStore.shared.recentlyPlayed),
            (tr("Frequently Played", "Häufig gespielt"),  LibraryStore.shared.frequentlyPlayed),
        ]
        for (header, albums) in categories where !albums.isEmpty {
            let items = albums.map { album -> CPListItem in
                let item = albumListItem(album) { [weak self] _, c in
                    guard let self else { c(); return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                    c()
                }
                if let id = album.coverArt, let img = imageMap[id] { item.setImage(img) }
                return item
            }
            sections.append(CPListSection(items: items, header: header, sectionIndexTitle: nil))
        }

        let random = LibraryStore.shared.randomAlbums
        if !random.isEmpty {
            let refreshIcon = (UIImage(systemName: "arrow.clockwise") ?? UIImage())
                .withTintColor(.label, renderingMode: .alwaysOriginal)
            let refreshItem = CPListItem(text: tr("Refresh", "Aktualisieren"), detailText: nil)
            refreshItem.setImage(refreshIcon)
            refreshItem.handler = { [weak self] _, c in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await LibraryStore.shared.refreshRandomAlbums()
                    let s = self.buildSections()
                    self.rootTemplate.updateSections(s)
                    await self.enrichWithCovers()
                }
                c()
            }
            var items: [CPListItem] = [refreshItem]
            items += random.map { album -> CPListItem in
                let item = albumListItem(album) { [weak self] _, c in
                    guard let self else { c(); return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                    c()
                }
                if let id = album.coverArt, let img = imageMap[id] { item.setImage(img) }
                return item
            }
            sections.append(CPListSection(items: items, header: tr("Random", "Zufällig"), sectionIndexTitle: nil))
        }

        return sections
    }

    private func enrichWithCovers() async {
        let all = LibraryStore.shared.recentlyAdded
            + LibraryStore.shared.recentlyPlayed
            + LibraryStore.shared.frequentlyPlayed
            + LibraryStore.shared.randomAlbums
        let pairs = all.map { (item: CPListItem(text: "", detailText: nil), coverArtId: $0.coverArt) }
        let imageMap = await batchLoadCovers(pairs)
        guard !imageMap.isEmpty, !Task.isCancelled else { return }
        rootTemplate.updateSections(buildSections(imageMap: imageMap))
    }

    private func makeMixItem(_ title: String, type: String) -> CPListItem {
        let icon = (UIImage(systemName: "waveform.badge.magnifyingglass") ?? UIImage())
            .withTintColor(.label, renderingMode: .alwaysOriginal)
        let item = CPListItem(text: title, detailText: nil, image: icon, accessoryImage: nil, accessoryType: .none)
        item.handler = { _, c in
            Task {
                do {
                    let albums = try await SubsonicAPIService.shared.getAlbumList(type: type, size: 50)
                    var songs: [Song] = []
                    try await withThrowingTaskGroup(of: [Song].self) { group in
                        for album in albums.prefix(20) {
                            group.addTask {
                                (try? await SubsonicAPIService.shared.getAlbum(id: album.id).song) ?? []
                            }
                        }
                        for try await s in group { songs.append(contentsOf: s) }
                    }
                    guard !songs.isEmpty else { return }
                    await MainActor.run { AudioPlayerService.shared.play(songs: songs, startIndex: 0) }
                } catch { /* network error — user can retry */ }
            }
            c()
        }
        return item
    }
}
