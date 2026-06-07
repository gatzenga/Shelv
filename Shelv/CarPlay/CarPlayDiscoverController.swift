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

        // Downloads werden in CarPlay asynchron nach load() geladen.
        // Sobald songs sich ändert, Offline-State neu rendern damit die Mix-Buttons erscheinen.
        DownloadStore.shared.$songs
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard OfflineModeService.shared.isOffline else { return }
                self?.showOffline()
            }
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
        let allDownloads = DownloadStore.shared.songs
        var sections: [CPListSection] = []

        if !allDownloads.isEmpty {
            sections.append(CPListSection(items: [
                makeOfflineMixItem(String(localized: "play_all_downloads"),    type: "play"),
                makeOfflineMixItem(String(localized: "shuffle_all_downloads"), type: "shuffle"),
                makeOfflineMixItem(String(localized: "mix_latest_downloads"),  type: "newest"),
            ], header: "Mixes", sectionIndexTitle: nil))
        }

        let goOnline = CPListItem(text: String(localized: "go_online"), detailText: nil)
        goOnline.setImage(cpIcon("wifi"))
        goOnline.handler = { _, c in
            Task { @MainActor in OfflineModeService.shared.exitOfflineMode() }
            c()
        }
        sections.append(CPListSection(
            items: [goOnline],
            header: allDownloads.isEmpty ? String(localized: "you_are_offline") : nil,
            sectionIndexTitle: nil
        ))

        rootTemplate.updateSections(sections)
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
        let refreshItem = actionListItem(title: String(localized: "refresh"), systemImage: "arrow.clockwise") { [weak self] _, c in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.fetchAndBuild()
            }
            c()
        }
        rootTemplate.updateSections([
            CPListSection(items: [enable], header: String(localized: "no_connection"), sectionIndexTitle: nil),
            CPListSection(items: [refreshItem], header: nil, sectionIndexTitle: nil),
        ])
    }

    private func buildSections(imageMap: [String: UIImage] = [:]) -> [CPListSection] {
        var sections: [CPListSection] = []

        // Mixes — reine Textzeilen, sauber untereinander
        sections.append(CPListSection(items: [
            makeMixItem(String(localized: "mix_newest_tracks"),     type: "newest",   icon: "sparkles"),
            makeMixItem(String(localized: "mix_frequently_played"), type: "frequent", icon: "chart.bar.fill"),
            makeMixItem(String(localized: "mix_recently_played"),   type: "recent",   icon: "clock.fill"),
            makeMixItem(String(localized: "mix_shuffle_all"),       type: "random",   icon: "shuffle"),
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

    private func makeOfflineMixItem(_ title: String, type: String) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil)
        item.handler = { [weak self] _, c in
            c()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allDownloads = DownloadStore.shared.songs
                guard !allDownloads.isEmpty else { return }

                switch type {
                case "play":
                    let sorted = allDownloads.map { $0.asSong() }.sorted {
                        let a = stripArticle($0.artist ?? "").localizedStandardCompare(stripArticle($1.artist ?? ""))
                        if a != .orderedSame { return a == .orderedAscending }
                        let b = ($0.album ?? "").localizedStandardCompare($1.album ?? "")
                        if b != .orderedSame { return b == .orderedAscending }
                        let d0 = $0.discNumber ?? 0, d1 = $1.discNumber ?? 0
                        if d0 != d1 { return d0 < d1 }
                        return ($0.track ?? 0) < ($1.track ?? 0)
                    }
                    AudioPlayerService.shared.play(songs: Array(sorted.prefix(500)))

                case "shuffle":
                    let sampled = Array(allDownloads.shuffled().prefix(500)).map { $0.asSong() }
                    AudioPlayerService.shared.playShuffled(songs: sampled)

                default: // newest
                    let top100 = allDownloads.sorted { $0.addedAt > $1.addedAt }.prefix(100).map { $0.asSong() }
                    AudioPlayerService.shared.playShuffled(songs: Array(top100))
                }

                CarPlayNavigation.presentNowPlaying(on: self.interfaceController)

                // Mixes-Sektion zurücksetzen (analog zu makeMixItem)
                let snap = self.rootTemplate.sections
                if !snap.isEmpty {
                    var fresh = snap
                    fresh[0] = CPListSection(items: [
                        self.makeOfflineMixItem(String(localized: "play_all_downloads"),    type: "play"),
                        self.makeOfflineMixItem(String(localized: "shuffle_all_downloads"), type: "shuffle"),
                        self.makeOfflineMixItem(String(localized: "mix_latest_downloads"),  type: "newest"),
                    ], header: "Mixes", sectionIndexTitle: nil)
                    self.rootTemplate.updateSections(fresh)
                }
            }
        }
        return item
    }

    private func frequentMixSongs() async throws -> [Song] {
        // Toggle aktiv UND genug DB-Daten (≥ 50 einzigartige Songs) → DB, sonst serverseitig.
        if UserDefaults.standard.bool(forKey: "mixUseDatabase"),
           let serverId = SubsonicAPIService.shared.activeServer?.stableId,
           await PlayLogService.shared.distinctSongCount(serverId: serverId) >= 50 {
            let counts = await PlayLogService.shared.topSongs(
                serverId: serverId,
                from: .distantPast,
                to: Date(),
                limit: 50
            )
            if !counts.isEmpty {
                return try await SubsonicAPIService.shared.getSongsOrdered(ids: counts.map(\.songId))
            }
        }
        let allFrequent = try await SubsonicAPIService.shared.getAlbumList(type: "frequent", size: 500)
        let sorted = allFrequent.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        let maxPC = sorted.first?.playCount ?? 0
        let threshold = max(maxPC / 50, 1)
        var filtered = sorted.filter { ($0.playCount ?? 0) >= threshold }
        if filtered.count < 30 { filtered = Array(sorted.prefix(30)) }
        if filtered.count > 80 { filtered = Array(sorted.prefix(80)) }
        let songs = try await withThrowingTaskGroup(of: [Song].self) { group in
            for album in filtered {
                group.addTask { (try? await SubsonicAPIService.shared.getAlbum(id: album.id))?.song ?? [] }
            }
            var all: [Song] = []
            for try await albumSongs in group { all.append(contentsOf: albumSongs) }
            return all
        }
        return Array(songs.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(50))
    }

    private func recentMixSongs() async throws -> [Song] {
        // Toggle aktiv UND genug DB-Daten → DB, sonst serverseitig (album-basiert).
        if UserDefaults.standard.bool(forKey: "mixUseDatabase"),
           let serverId = SubsonicAPIService.shared.activeServer?.stableId,
           await PlayLogService.shared.distinctSongCount(serverId: serverId) >= 50 {
            let ids = await PlayLogService.shared.recentUniqueSongIds(serverId: serverId, limit: 50)
            if !ids.isEmpty {
                return try await SubsonicAPIService.shared.getSongsOrdered(ids: ids)
            }
        }
        return try await SubsonicAPIService.shared.getRecentSongs(limit: 50)
    }

    private func makeMixItem(_ title: String, type: String, icon: String? = nil) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil)
        if let icon { item.setImage(cpListIcon(icon)) }
        item.handler = { [weak self] _, c in
            c()
            Task { [weak self] in
                do {
                    guard let self else { return }
                    let songs: [Song]
                    switch type {
                    case "newest":   songs = try await SubsonicAPIService.shared.getNewestSongs()
                    case "frequent": songs = try await self.frequentMixSongs()
                    case "random":   songs = try await SubsonicAPIService.shared.getRandomSongs(size: 500)
                    default:         songs = try await self.recentMixSongs()
                    }
                    guard !songs.isEmpty else {
                        await MainActor.run { self.presentMixError(title: title, message: String(localized: "no_tracks_found")) }
                        return
                    }
                    await MainActor.run {
                        AudioPlayerService.shared.playShuffled(songs: songs)
                        CarPlayNavigation.presentNowPlaying(on: self.interfaceController)
                        let snap = self.rootTemplate.sections
                        if !snap.isEmpty {
                            var freshSections = snap
                            freshSections[0] = CPListSection(items: [
                                self.makeMixItem(String(localized: "mix_newest_tracks"),     type: "newest",   icon: "sparkles"),
                                self.makeMixItem(String(localized: "mix_frequently_played"), type: "frequent", icon: "chart.bar.fill"),
                                self.makeMixItem(String(localized: "mix_recently_played"),   type: "recent",   icon: "clock.fill"),
                                self.makeMixItem(String(localized: "mix_shuffle_all"),       type: "random",   icon: "shuffle"),
                            ], header: "Mixes", sectionIndexTitle: nil)
                            self.rootTemplate.updateSections(freshSections)
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
