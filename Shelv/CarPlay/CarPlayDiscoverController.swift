import CarPlay
import Combine

private let kPreviewCount = 4

@MainActor
final class CarPlayDiscoverController {
    private let interfaceController: CPInterfaceController
    private let serverStore: ServerStore
    let rootTemplate: CPListTemplate
    private var loadTask: Task<Void, Never>?
    private var coverLoadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var loadGeneration = 0
    private var lastActiveURLSignature: String?
    private var isSwitchingServerURL = false

    private var discoverContentIsEmpty: Bool {
        LibraryStore.shared.recentlyAdded.isEmpty
            && LibraryStore.shared.recentlyPlayed.isEmpty
            && LibraryStore.shared.frequentlyPlayed.isEmpty
            && LibraryStore.shared.randomAlbums.isEmpty
    }

    private var activeURLSignature: String? {
        guard let server = serverStore.activeServer else { return nil }
        return "\(server.id.uuidString)|\(server.activeURLSlot.rawValue)|\(server.activeBaseURL)"
    }

    init(interfaceController: CPInterfaceController, serverStore: ServerStore) {
        self.interfaceController = interfaceController
        self.serverStore = serverStore
        let t = CPListTemplate(title: String(localized: "discover"), sections: [])
        t.tabImage = UIImage(systemName: "sparkles")
        rootTemplate = t
    }

    func load() {
        lastActiveURLSignature = activeURLSignature

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

        serverStore.$servers
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.handleActiveURLSlotChanged() }
            .store(in: &cancellables)

        serverStore.$activeServerID
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.handleActiveURLSlotChanged() }
            .store(in: &cancellables)

        var lastThemeColor = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
        var lastDiscoveryPersonalization = Self.discoveryPersonalizationSignature()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let current = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                let personalization = Self.discoveryPersonalizationSignature()
                guard current != lastThemeColor || personalization != lastDiscoveryPersonalization else { return }
                lastThemeColor = current
                lastDiscoveryPersonalization = personalization
                if OfflineModeService.shared.isOffline {
                    self.showOffline()
                } else {
                    self.rootTemplate.updateSections(self.buildSections())
                    self.startCoverEnrichment()
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
        let generation = nextLoadGeneration()
        if OfflineModeService.shared.isOffline {
            showOffline()
            return
        }
        showLoading()
        loadTask = Task { await fetchAndBuild(generation: generation) }
    }

    private func showOffline() {
        setLoadingState(false)
        let allDownloads = DownloadStore.shared.songs
        var sections: [CPListSection] = []

        if !allDownloads.isEmpty {
            sections.append(CPListSection(items: [
                makeOfflineMixItem(String(localized: "play_all_downloads"),    type: "play"),
                makeOfflineMixItem(String(localized: "shuffle_all_downloads"), type: "shuffle"),
                makeOfflineMixItem(String(localized: "mix_latest_downloads"),  type: "newest"),
            ], header: "Mixes", sectionIndexTitle: nil))
        }

        let goOnline = actionListItem(title: String(localized: "go_online"), systemImage: "wifi") { _, c in
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

    private func manualRefresh(completion: @escaping () -> Void) {
        loadTask?.cancel()
        let generation = nextLoadGeneration()
        showLoading()
        completion()
        loadTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if await OfflineModeService.shared.beginUserInitiatedServerRefresh() {
                guard self.isCurrentLoad(generation) else { return }
                showNoConnection()
                return
            }
            defer { OfflineModeService.shared.finishUserInitiatedServerRefresh() }
            await self.fetchAndBuild(generation: generation, waitForNetworkReconnect: true)
        }
    }

    private func fetchAndBuild(generation: Int, waitForNetworkReconnect: Bool = false) async {
        if waitForNetworkReconnect {
            _ = await NetworkStatus.shared.waitUntilNetworkAvailable()
        } else {
            await NetworkStatus.shared.waitUntilReady()
        }
        guard isCurrentLoad(generation) else { return }
        guard NetworkStatus.shared.hasNetwork else {
            let message = SubsonicAPIError.networkError(URLError(.notConnectedToInternet)).localizedDescription
            OfflineModeService.shared.notifyServerErrorIfPresentationAllowed(message)
            showNoConnection()
            return
        }
        async let discover: Bool = LibraryStore.shared.loadDiscover()
        async let random:   Void = LibraryStore.shared.refreshRandomAlbums()
        async let radio:    Void = RadioStationStore.shared.refresh(waitForCloudMetadata: false)
        _ = await (discover, random, radio)
        guard isCurrentLoad(generation) else { return }

        if discoverContentIsEmpty {
            showNoConnection()
            LibraryStore.shared.errorMessage = nil
            return
        }

        setLoadingState(false)
        rootTemplate.updateSections(buildSections())
        guard isCurrentLoad(generation) else { return }
        startCoverEnrichment()
    }

    private func showLoading() {
        coverLoadTask?.cancel()
        if #available(iOS 18.4, *) {
            setLoadingState(true)
            rootTemplate.updateSections([])
        } else {
            setLoadingState(false)
            let item = CPListItem(text: String(localized: "loading"), detailText: nil)
            item.setImage(cpListIcon("arrow.clockwise"))
            rootTemplate.updateSections([
                CPListSection(items: [item], header: nil, sectionIndexTitle: nil)
            ])
        }
    }

    private func showNoConnection() {
        setLoadingState(false)
        var items: [CPListItem] = [
            actionListItem(title: String(localized: "enable_offline_mode"), systemImage: "wifi.slash") { _, completion in
                Task { @MainActor in OfflineModeService.shared.enterOfflineMode() }
                completion()
            }
        ]
        if let switchItem = makeServerURLSwitchItem() {
            items.append(switchItem)
        }
        items.append(actionListItem(title: String(localized: "refresh"), systemImage: "arrow.clockwise") { [weak self] _, c in
            self?.manualRefresh(completion: c) ?? c()
        })
        rootTemplate.updateSections([
            CPListSection(items: items, header: String(localized: "no_connection"), sectionIndexTitle: nil)
        ])
    }

    private func setLoadingState(_ isLoading: Bool) {
        rootTemplate.emptyViewTitleVariants = []
        rootTemplate.emptyViewSubtitleVariants = []
        if #available(iOS 18.4, *) {
            rootTemplate.showsSpinnerWhileEmpty = isLoading
        }
    }

    private func makeServerURLSwitchItem() -> CPListItem? {
        guard let server = serverStore.activeServer, server.hasSecondaryURL else { return nil }
        let target: ServerURLSlot = server.isUsingSecondaryURL ? .primary : .secondary
        let title = target == .primary
            ? String(localized: "switch_to_primary_url")
            : String(localized: "switch_to_secondary_url")
        return actionListItem(title: title, systemImage: "arrow.triangle.2.circlepath") { [weak self] _, completion in
            self?.switchServerURLSlot(to: target, completion: completion) ?? completion()
        }
    }

    private func switchServerURLSlot(to slot: ServerURLSlot, completion: @escaping () -> Void) {
        loadTask?.cancel()
        let generation = nextLoadGeneration()
        guard let server = serverStore.activeServer else {
            completion()
            return
        }
        guard slot == .primary || server.hasSecondaryURL else {
            completion()
            return
        }

        showLoading()
        isSwitchingServerURL = true
        loadTask = Task { @MainActor [weak self] in
            guard let self else {
                completion()
                return
            }
            await self.serverStore.setURLSlot(for: server.id, slot: slot)
            guard self.isCurrentLoad(generation) else {
                completion()
                return
            }
            self.lastActiveURLSignature = self.activeURLSignature
            RadioStationStore.shared.resetInMemory()
            completion()
            defer {
                if self.isCurrentLoad(generation) {
                    self.isSwitchingServerURL = false
                }
            }
            if await OfflineModeService.shared.beginUserInitiatedServerRefresh() {
                guard self.isCurrentLoad(generation) else { return }
                showNoConnection()
                return
            }
            defer { OfflineModeService.shared.finishUserInitiatedServerRefresh() }
            await self.fetchAndBuild(generation: generation, waitForNetworkReconnect: true)
        }
    }

    private func handleActiveURLSlotChanged() {
        let signature = activeURLSignature
        guard signature != lastActiveURLSignature else { return }
        lastActiveURLSignature = signature
        guard !isSwitchingServerURL else { return }
        reloadAfterExternalServerURLChange()
    }

    private func reloadAfterExternalServerURLChange() {
        loadTask?.cancel()
        let generation = nextLoadGeneration()
        showLoading()
        RadioStationStore.shared.resetInMemory()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if await OfflineModeService.shared.beginUserInitiatedServerRefresh(presentsServerError: false) {
                guard self.isCurrentLoad(generation) else { return }
                showNoConnection()
                return
            }
            defer { OfflineModeService.shared.finishUserInitiatedServerRefresh() }
            await self.fetchAndBuild(generation: generation, waitForNetworkReconnect: true)
        }
    }

    private func nextLoadGeneration() -> Int {
        loadGeneration += 1
        return loadGeneration
    }

    private func isCurrentLoad(_ generation: Int) -> Bool {
        generation == loadGeneration && !Task.isCancelled
    }

    private func buildSections(imageMap: [String: UIImage] = [:]) -> [CPListSection] {
        setLoadingState(false)
        var sections: [CPListSection] = []

        let visibleSections = visibleDiscoverySections()
        for (index, section) in visibleSections.enumerated() {
            switch section {
            case .smartMixes:
                let mixes = visibleSmartMixes().map {
                    makeMixItem(
                        NSLocalizedString($0.titleKey, comment: ""),
                        type: $0.playbackKey,
                        icon: $0.systemImage
                    )
                }
                guard !mixes.isEmpty else { continue }
                let header = index == 0 ? nil : String(localized: "smart_mixes")
                sections.append(CPListSection(items: mixes, header: header, sectionIndexTitle: nil))
            case .recentlyAdded, .recentlyPlayed, .frequentlyPlayed, .randomAlbums:
                let albums = albums(for: section)
                guard !albums.isEmpty else { continue }
                let title = NSLocalizedString(section.titleKey, comment: "")
                sections.append(CPListSection(
                    items: [coverRowItem(title: title, albums: albums, imageMap: imageMap)],
                    header: nil,
                    sectionIndexTitle: nil
                ))
            }
        }

        // Refresh-Button ganz unten, kein Header
        let refreshItem = actionListItem(title: String(localized: "refresh"), systemImage: "arrow.clockwise") { [weak self] _, c in
            self?.manualRefresh(completion: c) ?? c()
        }
        sections.append(CPListSection(items: [refreshItem], header: nil, sectionIndexTitle: nil))

        return sections
    }

    private func visibleSmartMixes() -> [PersonalizationSmartMix] {
        PersonalizationSmartMix.allCases.filter {
            PersonalizationSettings.isSmartMixEnabled($0)
        }
    }

    private func visibleDiscoverySections() -> [PersonalizationDiscoverySection] {
        let rawOrder = UserDefaults.standard.string(forKey: PersonalizationPreferenceKey.discoverySectionOrder)
        return PersonalizationSettings.discoverySectionOrder(from: rawOrder)
            .filter(isDiscoverySectionVisible)
    }

    private func isDiscoverySectionVisible(_ section: PersonalizationDiscoverySection) -> Bool {
        switch section {
        case .smartMixes:
            return !visibleSmartMixes().isEmpty && !discoverContentIsEmpty
        case .recentlyAdded, .recentlyPlayed, .frequentlyPlayed, .randomAlbums:
            return !albums(for: section).isEmpty
        }
    }

    private func albums(for section: PersonalizationDiscoverySection) -> [Album] {
        switch section {
        case .smartMixes:
            return []
        case .recentlyAdded:
            return LibraryStore.shared.recentlyAdded
        case .recentlyPlayed:
            return LibraryStore.shared.recentlyPlayed
        case .frequentlyPlayed:
            return LibraryStore.shared.frequentlyPlayed
        case .randomAlbums:
            return LibraryStore.shared.randomAlbums
        }
    }

    private static func discoveryPersonalizationSignature(
        defaults: UserDefaults = .standard
    ) -> String {
        let order = defaults.string(forKey: PersonalizationPreferenceKey.discoverySectionOrder) ?? ""
        let mixes = PersonalizationSmartMix.allCases
            .map { mix in
                "\(mix.rawValue)=\(PersonalizationSettings.isSmartMixEnabled(mix, in: defaults))"
            }
            .joined(separator: ";")
        return "\(order)|\(mixes)"
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

    private func startCoverEnrichment() {
        coverLoadTask?.cancel()
        coverLoadTask = Task { await enrichWithCovers() }
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
                        self.rootTemplate.updateSections(self.buildSections())
                        self.startCoverEnrichment()
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
