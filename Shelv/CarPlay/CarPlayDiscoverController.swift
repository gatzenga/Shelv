import CarPlay
import Combine

private let kPreviewCount = 4

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
        goOnline.setImage(cpIcon("wifi"))
        goOnline.handler = { _, c in
            Task { @MainActor in OfflineModeService.shared.exitOfflineMode() }
            c()
        }
        rootTemplate.updateSections([CPListSection(
            items: [goOnline],
            header: tr("You are offline", "Du bist offline"),
            sectionIndexTitle: nil
        )])
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

        rootTemplate.updateSections(buildSections())
        guard !Task.isCancelled else { return }
        await enrichWithCovers()
    }

    private func showNoConnection() {
        let enable = CPListItem(text: tr("Enable Offline Mode", "Offline-Modus aktivieren"), detailText: nil)
        enable.setImage(cpIcon("wifi.slash"))
        enable.handler = { _, c in
            Task { @MainActor in OfflineModeService.shared.enterOfflineMode() }
            c()
        }
        rootTemplate.updateSections([CPListSection(
            items: [enable],
            header: tr("No connection", "Keine Verbindung"),
            sectionIndexTitle: nil
        )])
    }

    private func buildSections(imageMap: [String: UIImage] = [:]) -> [CPListSection] {
        var sections: [CPListSection] = []

        // Mixes — reine Textzeilen, sauber untereinander
        sections.append(CPListSection(items: [
            makeMixItem(tr("Mix: Newest Tracks",     "Mix: Neueste Titel"),     type: "newest"),
            makeMixItem(tr("Mix: Frequently Played", "Mix: Häufig gespielt"),   type: "frequent"),
            makeMixItem(tr("Mix: Recently Played",   "Mix: Kürzlich gespielt"), type: "recent"),
        ], header: "Mixes", sectionIndexTitle: nil))

        // Category image rows: each category = one CPListImageRowItem with 4 covers
        let categories: [(String, [Album])] = [
            (tr("Recently Added",    "Zuletzt hinzugefügt"), LibraryStore.shared.recentlyAdded),
            (tr("Recently Played",   "Zuletzt gespielt"),    LibraryStore.shared.recentlyPlayed),
            (tr("Frequently Played", "Häufig gespielt"),     LibraryStore.shared.frequentlyPlayed),
        ]

        var categoryRows: [any CPListTemplateItem] = []
        for (title, albums) in categories where !albums.isEmpty {
            categoryRows.append(coverRowItem(title: title, albums: albums, imageMap: imageMap))
        }
        if !categoryRows.isEmpty {
            sections.append(CPListSection(items: categoryRows, header: nil, sectionIndexTitle: nil))
        }

        // Random
        let random = LibraryStore.shared.randomAlbums
        if !random.isEmpty {
            let refreshItem = actionListItem(title: tr("Refresh", "Aktualisieren"), systemImage: "arrow.clockwise") { [weak self] _, c in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await LibraryStore.shared.refreshRandomAlbums()
                    self.rootTemplate.updateSections(self.buildSections())
                    await self.enrichWithCovers()
                }
                c()
            }
            let randomRow = coverRowItem(title: tr("Random", "Zufällig"), albums: random, imageMap: imageMap)
            let randomItems: [any CPListTemplateItem] = [refreshItem, randomRow]
            sections.append(CPListSection(items: randomItems, header: tr("Random", "Zufällig"), sectionIndexTitle: nil))
        }

        return sections
    }

    private func coverRowItem(title: String, albums: [Album], imageMap: [String: UIImage]) -> CPListImageRowItem {
        let preview = Array(albums.prefix(kPreviewCount))
        let covers: [UIImage] = preview.map { album in
            if let id = album.coverArt, let img = imageMap[id] { return img }
            return cpPlaceholder
        }
        let row = makeImageRowItem(text: title, images: covers)
        row.listImageRowHandler = { [weak self] _, idx, c in
            guard let self, idx < preview.count else { c(); return }
            CarPlayNavigation.openAlbum(preview[idx], from: self.interfaceController)
            c()
        }
        row.handler = { [weak self] _, c in
            guard let self else { c(); return }
            self.pushFullAlbumList(title: title, albums: albums)
            c()
        }
        return row
    }

    private func pushFullAlbumList(title: String, albums: [Album]) {
        let template = CPListTemplate(title: title, sections: [
            CPListSection(items: makeAlbumItems(albums, imageMap: [:]), header: nil, sectionIndexTitle: nil)
        ])
        CarPlayNavigation.safePush(template, on: interfaceController)
        Task { [weak self] in
            guard let self else { return }
            await applyCoversAsync(template: template, coverArtIds: albums.map { $0.coverArt }) { [weak self] map in
                guard let self else { return [] }
                return [CPListSection(items: self.makeAlbumItems(albums, imageMap: map), header: nil, sectionIndexTitle: nil)]
            }
        }
    }

    private func makeAlbumItems(_ albums: [Album], imageMap: [String: UIImage]) -> [CPListItem] {
        albums.map { album -> CPListItem in
            let item = albumListItem(album) { [weak self] _, c in
                guard let self else { c(); return }
                CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                c()
            }
            if let id = album.coverArt, let img = imageMap[id] { item.setImage(img) }
            return item
        }
    }

    private func enrichWithCovers() async {
        let all = LibraryStore.shared.recentlyAdded
            + LibraryStore.shared.recentlyPlayed
            + LibraryStore.shared.frequentlyPlayed
            + LibraryStore.shared.randomAlbums
        let ids = all.map { $0.coverArt }
        await applyCoversAsync(template: rootTemplate, coverArtIds: ids) { [weak self] map in
            self?.buildSections(imageMap: map) ?? []
        }
    }

    private func makeMixItem(_ title: String, type: String) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil)
        item.handler = { [weak self] _, c in
            // c() in den Task verschoben → CarPlay zeigt Loading-Spinner bis Aufruf zurück.
            Task { [weak self] in
                do {
                    let albums = try await SubsonicAPIService.shared.getAlbumList(type: type, size: 50)
                    var songs: [Song] = []
                    try await withThrowingTaskGroup(of: [Song].self) { group in
                        for album in albums.prefix(20) {
                            group.addTask { (try? await SubsonicAPIService.shared.getAlbum(id: album.id).song) ?? [] }
                        }
                        for try await s in group { songs.append(contentsOf: s) }
                    }
                    guard !songs.isEmpty else {
                        await MainActor.run { self?.presentMixError(title: title, message: tr("No tracks found.", "Keine Titel gefunden.")) }
                        c()
                        return
                    }
                    await MainActor.run { AudioPlayerService.shared.play(songs: songs, startIndex: 0) }
                    c()
                } catch {
                    await MainActor.run { self?.presentMixError(title: title, message: error.localizedDescription) }
                    c()
                }
            }
        }
        return item
    }

    private func presentMixError(title: String, message: String) {
        // titleVariants nach Display-Breite — längste zuerst, fallback auf kurze.
        let long  = "\(title) — \(message)"
        let alert = CPAlertTemplate(
            titleVariants: [long, title, tr("Mix failed", "Mix fehlgeschlagen")],
            actions: [
                CPAlertAction(title: tr("OK", "OK"), style: .default) { [weak self] _ in
                    self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                }
            ]
        )
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}
