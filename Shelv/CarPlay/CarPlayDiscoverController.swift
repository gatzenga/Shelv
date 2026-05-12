import CarPlay
import Combine

private let kPreviewCount = 4

@MainActor
final class CarPlayDiscoverController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var loadTask: Task<Void, Never>?
    private var coverLoadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let t = CPListTemplate(title: String(localized: "discover"), sections: [])
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

        var lastThemeColor = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let current = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                guard current != lastThemeColor else { return }
                lastThemeColor = current
                if OfflineModeService.shared.isOffline {
                    self.showOffline()
                } else {
                    self.rootTemplate.updateSections(self.buildSections())
                    Task { await self.enrichWithCovers() }
                }
            }
            .store(in: &cancellables)

        reload()
    }

    func cancel() {
        loadTask?.cancel()
        coverLoadTask?.cancel()
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
        let goOnline = CPListItem(text: String(localized: "go_online"), detailText: nil)
        goOnline.setImage(cpIcon("wifi"))
        goOnline.handler = { _, c in
            Task { @MainActor in OfflineModeService.shared.exitOfflineMode() }
            c()
        }
        rootTemplate.updateSections([CPListSection(
            items: [goOnline],
            header: String(localized: "you_are_offline"),
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
        let enable = CPListItem(text: String(localized: "enable_offline_mode"), detailText: nil)
        enable.setImage(cpIcon("wifi.slash"))
        enable.handler = { _, c in
            Task { @MainActor in OfflineModeService.shared.enterOfflineMode() }
            c()
        }
        rootTemplate.updateSections([CPListSection(
            items: [enable],
            header: String(localized: "no_connection"),
            sectionIndexTitle: nil
        )])
    }

    private func buildSections(imageMap: [String: UIImage] = [:]) -> [CPListSection] {
        var sections: [CPListSection] = []

        // Mixes — reine Textzeilen, sauber untereinander
        sections.append(CPListSection(items: [
            makeMixItem(String(localized: "mix_newest_tracks"),     type: "newest"),
            makeMixItem(String(localized: "mix_frequently_played"),   type: "frequent"),
            makeMixItem(String(localized: "mix_recently_played"), type: "recent"),
        ], header: "Mixes", sectionIndexTitle: nil))

        // 4 Kategorien als Cover-Rows, kein Section-Header
        let categories: [(String, [Album])] = [
            (String(localized: "recently_added"), LibraryStore.shared.recentlyAdded),
            (String(localized: "recently_played"),    LibraryStore.shared.recentlyPlayed),
            (String(localized: "frequently_played"),     LibraryStore.shared.frequentlyPlayed),
            (String(localized: "random"),            LibraryStore.shared.randomAlbums),
        ]

        var categoryRows: [any CPListTemplateItem] = []
        for (title, albums) in categories where !albums.isEmpty {
            categoryRows.append(coverRowItem(title: title, albums: albums, imageMap: imageMap))
        }
        if !categoryRows.isEmpty {
            sections.append(CPListSection(items: categoryRows, header: nil, sectionIndexTitle: nil))
        }

        // Refresh-Button ganz unten, kein Header
        let refreshItem = actionListItem(title: String(localized: "refresh"), systemImage: "arrow.clockwise") { [weak self] _, c in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.fetchAndBuild()
            }
            c()
        }
        sections.append(CPListSection(items: [refreshItem], header: nil, sectionIndexTitle: nil))

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
            c()
            CarPlayNavigation.openAlbum(preview[idx], from: self.interfaceController)
        }
        row.handler = { [weak self] _, c in
            guard let self else { c(); return }
            self.pushFullAlbumList(title: title, albums: albums)
            c()
        }
        return row
    }

    private func pushFullAlbumList(title: String, albums: [Album]) {
        var itemsByCoverId: [String: [CPListItem]] = [:]
        let items = albums.map { album -> CPListItem in
            let item = albumListItem(album) { [weak self] _, c in
                guard let self else { c(); return }
                c()
                CarPlayNavigation.openAlbum(album, from: self.interfaceController)
            }
            if let id = album.coverArt { itemsByCoverId[id, default: []].append(item) }
            return item
        }
        let template = CPListTemplate(title: title, sections: [
            CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        ])
        CarPlayNavigation.safePush(template, on: interfaceController)
        guard !itemsByCoverId.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task { await streamCovers(into: itemsByCoverId) }
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
            c()
            Task { [weak self] in
                do {
                    let songs: [Song]
                    switch type {
                    case "newest":   songs = try await SubsonicAPIService.shared.getNewestSongs()
                    case "frequent": songs = try await SubsonicAPIService.shared.getFrequentSongs(limit: 50)
                    default:         songs = try await SubsonicAPIService.shared.getRecentSongs(limit: 50)
                    }
                    guard !songs.isEmpty else {
                        await MainActor.run { self?.presentMixError(title: title, message: String(localized: "no_tracks_found")) }
                        return
                    }
                    if let s = self {
                        await MainActor.run {
                            AudioPlayerService.shared.playShuffled(songs: songs)
                            CarPlayNavigation.presentNowPlaying(on: s.interfaceController)
                            let snap = s.rootTemplate.sections
                            if !snap.isEmpty {
                                var freshSections = snap
                                freshSections[0] = CPListSection(items: [
                                    s.makeMixItem(String(localized: "mix_newest_tracks"),     type: "newest"),
                                    s.makeMixItem(String(localized: "mix_frequently_played"),   type: "frequent"),
                                    s.makeMixItem(String(localized: "mix_recently_played"), type: "recent"),
                                ], header: "Mixes", sectionIndexTitle: nil)
                                s.rootTemplate.updateSections(freshSections)
                            }
                        }
                    }
                } catch {
                    await MainActor.run { self?.presentMixError(title: title, message: error.localizedDescription) }
                }
            }
        }
        return item
    }

    private func presentMixError(title: String, message: String) {
        // titleVariants nach Display-Breite — längste zuerst, fallback auf kurze.
        let long  = "\(title) — \(message)"
        let alert = CPAlertTemplate(
            titleVariants: [long, title, String(localized: "mix_failed")],
            actions: [
                CPAlertAction(title: String(localized: "ok"), style: .default) { [weak self] _ in
                    self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                }
            ]
        )
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}
