import CarPlay
import Combine

private let kPreviewCount = FavoritePresentation.previewLimit

private struct CarPlaySectionBuild {
    let sections: [CPListSection]
    let itemsByCoverId: [String: [CPListItem]]
    let orderedCoverArtIds: [String]
}

@MainActor
final class CarPlayLibraryController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var cancellables = Set<AnyCancellable>()
    // Eigene Task-Variable pro Screen — verhindert gegenseitiges Canceln (Szenario B)
    private var albumLoadTask: Task<Void, Never>?
    private var albumCoverTask: Task<Void, Never>?
    private var artistLoadTask: Task<Void, Never>?
    private var artistCoverTask: Task<Void, Never>?
    private var coverLoadTask: Task<Void, Never>?
    private var lastShowFavoritesInLibrary: Bool = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showFavoritesInLibrary)
    private var lastThemeColor: String = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
    private weak var albumsTemplate: CPListTemplate?
    private weak var artistsTemplate: CPListTemplate?
    private weak var favoritesTemplate: CPListTemplate?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let isOffline = OfflineModeService.shared.isOffline
        let title = isOffline ? String(localized: "downloads") : String(localized: "library")
        let t = CPListTemplate(title: title, sections: [])
        t.tabTitle = title
        t.tabImage = UIImage(systemName: isOffline ? "internaldrive" : "books.vertical")
        rootTemplate = t
    }

    func load() {
        OfflineModeService.shared.$isOffline
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)

        LibraryStore.shared.$reloadID
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)

        // UserDefaults.didChangeNotification feuert bei jeder Mutation (Player-State-Saves
        // alle paar Sekunden) — nur bei tatsächlicher Änderung des relevanten Keys reagieren.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let currentFav   = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showFavoritesInLibrary)
                let currentTheme = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                if currentFav != self.lastShowFavoritesInLibrary {
                    self.lastShowFavoritesInLibrary = currentFav
                    self.buildMenu()
                }
                if currentTheme != self.lastThemeColor {
                    self.lastThemeColor = currentTheme
                    self.buildMenu()
                    self.rebuildAlbumsTemplate()
                    self.rebuildArtistsTemplate()
                    self.rebuildFavoritesTemplate()
                }
            }
            .store(in: &cancellables)

        // Offline-Start-Fix: DownloadStore lädt async — $albums und $artists sind separate
        // @Published Properties, die getrennt feuern. Deshalb je ein eigener Subscriber,
        // damit rebuildArtistsTemplate() erst läuft wenn artists tatsächlich befüllt sind.
        DownloadStore.shared.$albums
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .filter { _ in OfflineModeService.shared.isOffline }
            .sink { [weak self] _ in
                guard let self else { return }
                self.buildMenu()
                self.rebuildAlbumsTemplate()
                self.rebuildFavoritesTemplate()
            }
            .store(in: &cancellables)

        DownloadStore.shared.$artists
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .filter { _ in OfflineModeService.shared.isOffline }
            .sink { [weak self] _ in self?.rebuildArtistsTemplate() }
            .store(in: &cancellables)

        LibraryStore.shared.$starredSongs
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.rebuildFavoritesTemplate() }
            .store(in: &cancellables)

        LibraryStore.shared.$albums
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.rebuildAlbumsTemplate() }
            .store(in: &cancellables)

        LibraryStore.shared.$artists
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.rebuildArtistsTemplate() }
            .store(in: &cancellables)

        buildMenu()
    }

    func cancel() {
        albumLoadTask?.cancel()
        albumCoverTask?.cancel()
        artistLoadTask?.cancel()
        artistCoverTask?.cancel()
        coverLoadTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Menu

    private func buildMenu() {
        let isOffline = OfflineModeService.shared.isOffline

        // Tab-Titel und -Icon reaktiv aktualisieren (tabTitle ist auf CPTemplate nachträglich settable)
        rootTemplate.tabTitle = isOffline ? String(localized: "downloads") : String(localized: "library")
        rootTemplate.tabImage = UIImage(systemName: isOffline ? "internaldrive" : "books.vertical")

        var items: [CPListItem] = [
            menuListItem(title: String(localized: "albums"), systemImage: "square.stack") { [weak self] _, c in
                c(); self?.pushAlbumsList()
            },
            menuListItem(title: String(localized: "artists"), systemImage: "music.microphone") { [weak self] _, c in
                c(); self?.pushArtistsList()
            },
        ]
        if UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showFavoritesInLibrary) {
            items.append(menuListItem(title: String(localized: "favorites"), systemImage: "heart") { [weak self] _, c in
                c(); self?.pushFavorites()
            })
        }
        rootTemplate.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
    }

    // MARK: - Albums (alphabetische Abschnitte + Buchstabenleiste)

    private func rebuildAlbumsTemplate() {
        Task { @MainActor [weak self] in
            guard let self, let t = self.albumsTemplate else { return }
            let current = self.albumSource()
            guard !current.isEmpty else { return }
            let built = self.makeAlbumSections(current)
            self.applyAlbumSections(built, to: t)
        }
    }

    private func rebuildArtistsTemplate() {
        Task { @MainActor [weak self] in
            guard let self, let t = self.artistsTemplate else { return }
            let current = self.artistSource()
            guard !current.isEmpty else { return }
            let counts = self.albumCountByArtist()
            let built = self.makeArtistSections(current, counts: counts)
            self.applyArtistSections(built, to: t)
        }
    }

    private func rebuildFavoritesTemplate() {
        Task { @MainActor [weak self] in
            guard let self, let t = self.favoritesTemplate else { return }
            let songs   = self.starredSongs()
            let albums  = self.starredAlbums()
            let artists = self.starredArtists()
            let counts  = self.albumCountByArtist()
            let built = self.makeFavoriteSections(songs: songs, albums: albums, artists: artists, counts: counts)
            prefillCoversFromCache(built.itemsByCoverId)
            t.updateSections(built.sections)
            self.coverLoadTask?.cancel()
            self.coverLoadTask = Task {
                await streamCovers(into: built.itemsByCoverId, orderedCoverArtIds: built.orderedCoverArtIds)
            }
        }
    }

    private func pushAlbumsList() {
        let current = albumSource()
        let initialBuild: CarPlaySectionBuild?
        let template: CPListTemplate
        if current.isEmpty {
            let placeholder = CPListItem(text: String(localized: "loading"), detailText: nil)
            template = CPListTemplate(title: String(localized: "albums"), sections: [
                CPListSection(items: [placeholder], header: nil, sectionIndexTitle: nil)
            ])
            initialBuild = nil
        } else {
            let built = makeAlbumSections(current)
            prefillCoversFromCache(built.itemsByCoverId)
            template = CPListTemplate(title: String(localized: "albums"), sections: built.sections)
            initialBuild = built
        }
        albumsTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)

        // Eigene Load-Task — Cover-Rebuilds dürfen den Daten-Refresh nicht canceln.
        albumLoadTask?.cancel()
        albumCoverTask?.cancel()
        if let initialBuild {
            startAlbumCoverStream(initialBuild)
        }
        let shouldRefreshAlbums = !OfflineModeService.shared.isOffline
        albumLoadTask = Task {
            if shouldRefreshAlbums {
                await LibraryStore.shared.loadAlbums(sortBy: "alphabeticalByName")
            }
        }
    }

    private func applyAlbumSections(
        _ built: CarPlaySectionBuild,
        to template: CPListTemplate
    ) {
        prefillCoversFromCache(built.itemsByCoverId)
        template.updateSections(built.sections)
        startAlbumCoverStream(built)
    }

    private func startAlbumCoverStream(_ built: CarPlaySectionBuild) {
        albumCoverTask?.cancel()
        guard !built.itemsByCoverId.isEmpty else { return }
        albumCoverTask = Task {
            await streamCovers(into: built.itemsByCoverId, orderedCoverArtIds: built.orderedCoverArtIds)
        }
    }

    private func makeAlbumSections(_ albums: [Album]) -> CarPlaySectionBuild {
        let sorted = LibraryRepository.locallySortedAlbums(albums, sort: .name, direction: .ascending)
        let grouped = Dictionary(grouping: sorted) {
            firstSortLetter($0.name, sortName: $0.sortName)
        }
        let letters = grouped.keys.sorted()
        var remainingItems = CPListTemplate.maximumItemCount
        var itemsByCoverId: [String: [CPListItem]] = [:]
        var orderedCoverArtIds: [String] = []
        var sections: [CPListSection] = []
        for (letterIndex, letter) in letters.enumerated() {
            guard remainingItems > 0 else { break }
            let remainingLetters = max(1, letters.count - letterIndex)
            let cap = max(1, remainingItems / remainingLetters)
            var letterItems: [CPListItem] = []
            for album in (grouped[letter] ?? []).prefix(cap) {
                let item = albumListItem(album) { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                    self.rebuildAlbumsTemplate()
                }
                registerCoverItem(item, coverArtId: album.coverArt, itemsByCoverId: &itemsByCoverId, orderedCoverArtIds: &orderedCoverArtIds)
                letterItems.append(item)
            }
            remainingItems -= letterItems.count
            sections.append(CPListSection(items: letterItems, header: letter, sectionIndexTitle: letter))
        }
        return CarPlaySectionBuild(sections: sections, itemsByCoverId: itemsByCoverId, orderedCoverArtIds: orderedCoverArtIds)
    }

    private func albumSource() -> [Album] {
        if OfflineModeService.shared.isOffline {
            if LibraryStore.shared.albums.isEmpty {
                return DownloadStore.shared.albums.map { $0.asAlbum() }
            }
            let ids = Set(DownloadStore.shared.albums.map { $0.albumId })
            return LibraryStore.shared.albums.filter { ids.contains($0.id) }
        }
        return LibraryStore.shared.albums
    }

    // MARK: - Artists (alphabetische Abschnitte + Buchstabenleiste)

    private func pushArtistsList() {
        let current = artistSource()
        let counts = albumCountByArtist()
        let initialBuild: CarPlaySectionBuild?
        let template: CPListTemplate
        if current.isEmpty {
            let placeholder = CPListItem(text: String(localized: "loading"), detailText: nil)
            template = CPListTemplate(title: String(localized: "artists"), sections: [
                CPListSection(items: [placeholder], header: nil, sectionIndexTitle: nil)
            ])
            initialBuild = nil
        } else {
            let built = makeArtistSections(current, counts: counts)
            prefillCoversFromCache(built.itemsByCoverId)
            template = CPListTemplate(title: String(localized: "artists"), sections: built.sections)
            initialBuild = built
        }
        artistsTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)

        // Eigene Load-Task — Cover-Rebuilds dürfen den Daten-Refresh nicht canceln.
        artistLoadTask?.cancel()
        artistCoverTask?.cancel()
        if let initialBuild {
            startArtistCoverStream(initialBuild)
        }
        let shouldLoadArtists = current.isEmpty && !OfflineModeService.shared.isOffline
        artistLoadTask = Task {
            if shouldLoadArtists {
                await LibraryStore.shared.loadArtists()
            }
        }
    }

    private func applyArtistSections(
        _ built: CarPlaySectionBuild,
        to template: CPListTemplate
    ) {
        prefillCoversFromCache(built.itemsByCoverId)
        template.updateSections(built.sections)
        startArtistCoverStream(built)
    }

    private func startArtistCoverStream(_ built: CarPlaySectionBuild) {
        artistCoverTask?.cancel()
        guard !built.itemsByCoverId.isEmpty else { return }
        artistCoverTask = Task {
            await streamCovers(into: built.itemsByCoverId, orderedCoverArtIds: built.orderedCoverArtIds)
        }
    }

    private func makeArtistSections(_ artists: [Artist], counts: [String: Int]) -> CarPlaySectionBuild {
        let sorted = LibraryRepository.locallySortedArtists(artists)
        let grouped = Dictionary(grouping: sorted) {
            firstSortLetter($0.name, sortName: $0.sortName)
        }
        let letters = grouped.keys.sorted()
        var remainingItems = CPListTemplate.maximumItemCount
        var itemsByCoverId: [String: [CPListItem]] = [:]
        var orderedCoverArtIds: [String] = []
        var sections: [CPListSection] = []
        for (letterIndex, letter) in letters.enumerated() {
            guard remainingItems > 0 else { break }
            let remainingLetters = max(1, letters.count - letterIndex)
            let cap = max(1, remainingItems / remainingLetters)
            var letterItems: [CPListItem] = []
            for artist in (grouped[letter] ?? []).prefix(cap) {
                let count = counts[artist.id] ?? 0
                let item = artistListItem(artist, subtitle: "\(count) \(String(localized: "albums"))") { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openArtist(artist, from: self.interfaceController)
                    self.rebuildArtistsTemplate()
                }
                registerCoverItem(item, coverArtId: artist.coverArt, itemsByCoverId: &itemsByCoverId, orderedCoverArtIds: &orderedCoverArtIds)
                letterItems.append(item)
            }
            remainingItems -= letterItems.count
            sections.append(CPListSection(items: letterItems, header: letter, sectionIndexTitle: letter))
        }
        return CarPlaySectionBuild(sections: sections, itemsByCoverId: itemsByCoverId, orderedCoverArtIds: orderedCoverArtIds)
    }

    private func artistSource() -> [Artist] {
        if OfflineModeService.shared.isOffline {
            if LibraryStore.shared.artists.isEmpty {
                return DownloadStore.shared.artists.map { $0.asArtist() }
            }
            let names = Set(DownloadStore.shared.artists.map { $0.name })
            return LibraryStore.shared.artists.filter { names.contains($0.name) }
        }
        return LibraryStore.shared.artists
    }

    private func albumCountByArtist() -> [String: Int] {
        if OfflineModeService.shared.isOffline {
            // Im Offline können Künstler-Objekte aus zwei Quellen stammen (DownloadStore mit
            // "name:..."-Fallback-IDs, oder LibraryStore-Cache mit echten Server-UUIDs).
            // Map mit allen möglichen Lookup-Keys befüllen, damit der Aufruf-Code beliebige
            // Artist-Objekte durchreichen kann.
            var result: [String: Int] = [:]
            let downloads = DownloadStore.shared.artists
            for art in downloads {
                result[art.artistId] = art.albumCount
                result[art.name] = art.albumCount
            }
            for libArt in LibraryStore.shared.artists {
                if let match = downloads.first(where: { $0.name == libArt.name }) {
                    result[libArt.id] = match.albumCount
                }
            }
            return result
        }
        // Online: aus geladenen Albums gruppieren — fehlende Künstler erhalten Server-Wert
        // aus dem Artist-Objekt selbst (verhindert "0 Alben" wenn Albums-Liste leer ist).
        var result = Dictionary(grouping: LibraryStore.shared.albums, by: { $0.artistId ?? "" }).mapValues { $0.count }
        for artist in LibraryStore.shared.artists where result[artist.id] == nil {
            result[artist.id] = artist.albumCount ?? 0
        }
        return result
    }

    private func registerCoverItem(
        _ item: CPListItem,
        coverArtId: String?,
        itemsByCoverId: inout [String: [CPListItem]],
        orderedCoverArtIds: inout [String]
    ) {
        guard let coverArtId else { return }
        if itemsByCoverId[coverArtId] == nil {
            orderedCoverArtIds.append(coverArtId)
        }
        itemsByCoverId[coverArtId, default: []].append(item)
    }

    // MARK: - Favorites

    private func pushFavorites() {
        let songs   = starredSongs()
        let albums  = starredAlbums()
        let artists = starredArtists()
        let counts  = albumCountByArtist()

        let built = makeFavoriteSections(songs: songs, albums: albums, artists: artists, counts: counts)
        prefillCoversFromCache(built.itemsByCoverId)
        let template = CPListTemplate(title: String(localized: "favorites"), sections: built.sections)
        favoritesTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)

        // Wenn starredSongs noch nicht geladen — eigenständiger Task, unabhängig von coverLoadTask.
        // $starredSongs subscriber baut Template automatisch neu wenn loadStarred fertig ist.
        if LibraryStore.shared.starredSongs.isEmpty {
            Task { await LibraryStore.shared.loadStarred() }
        }

        guard !built.itemsByCoverId.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task {
            await streamCovers(into: built.itemsByCoverId, orderedCoverArtIds: built.orderedCoverArtIds)
        }
    }

    private func makeFavoriteSections(
        songs: [Song], albums: [Album], artists: [Artist],
        counts: [String: Int]
    ) -> CarPlaySectionBuild {
        var sections: [CPListSection] = []
        var itemsByCoverId: [String: [CPListItem]] = [:]
        var orderedCoverArtIds: [String] = []

        if !songs.isEmpty {
            var items: [CPListItem] = []
            for (idx, song) in songs.prefix(kPreviewCount).enumerated() {
                let item = songListItem(song, index: idx, showCover: true) { [weak self] _, c in
                    c()
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx)
                    if let self { CarPlayNavigation.presentNowPlaying(on: self.interfaceController) }
                    self?.rebuildFavoritesTemplate()
                }
                registerCoverItem(item, coverArtId: song.coverArt, itemsByCoverId: &itemsByCoverId, orderedCoverArtIds: &orderedCoverArtIds)
                items.append(item)
            }
            if songs.count > kPreviewCount {
                items.append(showAllListItem(title: String(format: String(localized: "show_all_count_format"), songs.count)) { [weak self] _, c in
                    c(); self?.pushFullFavoriteSongs(songs)
                })
            }
            sections.append(CPListSection(items: items, header: String(localized: "songs"), sectionIndexTitle: nil))
        }

        if !albums.isEmpty {
            var items: [CPListItem] = []
            for album in albums.prefix(kPreviewCount) {
                let item = albumListItem(album) { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                    self.rebuildFavoritesTemplate()
                }
                registerCoverItem(item, coverArtId: album.coverArt, itemsByCoverId: &itemsByCoverId, orderedCoverArtIds: &orderedCoverArtIds)
                items.append(item)
            }
            if albums.count > kPreviewCount {
                items.append(showAllListItem(title: String(format: String(localized: "show_all_count_format"), albums.count)) { [weak self] _, c in
                    c(); self?.pushFullFavoriteAlbums(albums)
                })
            }
            sections.insert(
                CPListSection(items: items, header: String(localized: "albums"), sectionIndexTitle: nil),
                at: 0
            )
        }

        if !artists.isEmpty {
            var items: [CPListItem] = []
            for artist in artists.prefix(kPreviewCount) {
                let count = counts[artist.id] ?? 0
                let item = artistListItem(artist, subtitle: "\(count) \(String(localized: "albums"))") { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openArtist(artist, from: self.interfaceController)
                    self.rebuildFavoritesTemplate()
                }
                registerCoverItem(item, coverArtId: artist.coverArt, itemsByCoverId: &itemsByCoverId, orderedCoverArtIds: &orderedCoverArtIds)
                items.append(item)
            }
            if artists.count > kPreviewCount {
                items.append(showAllListItem(title: String(format: String(localized: "show_all_count_format"), artists.count)) { [weak self] _, c in
                    c(); self?.pushFullFavoriteArtists(artists)
                })
            }
            sections.append(CPListSection(items: items, header: String(localized: "artists"), sectionIndexTitle: nil))
        }

        if sections.isEmpty {
            let empty = CPListItem(text: String(localized: "no_favorites_yet"), detailText: nil)
            sections = [CPListSection(items: [empty], header: nil, sectionIndexTitle: nil)]
        }
        return CarPlaySectionBuild(sections: sections, itemsByCoverId: itemsByCoverId, orderedCoverArtIds: orderedCoverArtIds)
    }

    private func starredSongs() -> [Song] {
        let all = LibraryStore.shared.starredSongs
        if OfflineModeService.shared.isOffline {
            let ids = Set(DownloadStore.shared.songs.map { $0.songId })
            return all.filter { ids.contains($0.id) }
        }
        return all
    }

    private func starredAlbums() -> [Album] {
        let all = LibraryStore.shared.starredAlbums
        if OfflineModeService.shared.isOffline {
            let ids = Set(DownloadStore.shared.albums.map { $0.albumId })
            return all.filter { ids.contains($0.id) }
        }
        return all
    }

    private func starredArtists() -> [Artist] { LibraryStore.shared.starredArtists }

    // MARK: - Full Favorite Lists

    private func pushFullFavoriteSongs(_ songs: [Song]) {
        weak var weakTemplate: CPListTemplate?
        func makeSongsSection() -> (section: CPListSection, coverMap: [String: [CPListItem]], coverIds: [String]) {
            var coverMap: [String: [CPListItem]] = [:]
            var coverIds: [String] = []
            let items = songs.enumerated().map { idx, song -> CPListItem in
                let item = songListItem(song, index: idx, showCover: true) { [weak self] _, c in
                    c()
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx)
                    if let self { CarPlayNavigation.presentNowPlaying(on: self.interfaceController) }
                    Task { @MainActor [weak self] in
                        guard let self, let template = weakTemplate else { return }
                        let fresh = makeSongsSection()
                        prefillCoversFromCache(fresh.coverMap)
                        template.updateSections([fresh.section])
                        self.coverLoadTask?.cancel()
                        self.coverLoadTask = Task {
                            await streamCovers(into: fresh.coverMap, orderedCoverArtIds: fresh.coverIds)
                        }
                    }
                }
                if let id = song.coverArt {
                    if coverMap[id] == nil { coverIds.append(id) }
                    coverMap[id, default: []].append(item)
                }
                return item
            }
            return (
                CPListSection(items: items, header: nil, sectionIndexTitle: nil),
                coverMap,
                coverIds
            )
        }
        let built = makeSongsSection()
        prefillCoversFromCache(built.coverMap)
        let template = CPListTemplate(title: String(localized: "favorite_songs"), sections: [built.section])
        weakTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)
        guard !built.coverMap.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task {
            await streamCovers(into: built.coverMap, orderedCoverArtIds: built.coverIds)
        }
    }

    private func pushFullFavoriteAlbums(_ albums: [Album]) {
        weak var weakTemplate: CPListTemplate?
        func makeItems() -> (items: [CPListItem], coverMap: [String: [CPListItem]], coverIds: [String]) {
            var coverMap: [String: [CPListItem]] = [:]
            var coverIds: [String] = []
            let items = albums.map { album -> CPListItem in
                let item = albumListItem(album) { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                    Task { @MainActor [weak self] in
                        guard let self, let t = weakTemplate else { return }
                        let (freshItems, freshMap, freshIds) = makeItems()
                        prefillCoversFromCache(freshMap)
                        t.updateSections([CPListSection(items: freshItems, header: nil, sectionIndexTitle: nil)])
                        self.coverLoadTask?.cancel()
                        self.coverLoadTask = Task { await streamCovers(into: freshMap, orderedCoverArtIds: freshIds) }
                    }
                }
                if let id = album.coverArt {
                    if coverMap[id] == nil { coverIds.append(id) }
                    coverMap[id, default: []].append(item)
                }
                return item
            }
            return (items, coverMap, coverIds)
        }
        let (items, coverMap, coverIds) = makeItems()
        prefillCoversFromCache(coverMap)
        let template = CPListTemplate(title: String(localized: "favorite_albums"), sections: [
            CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        ])
        weakTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)
        guard !coverMap.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task { await streamCovers(into: coverMap, orderedCoverArtIds: coverIds) }
    }

    private func pushFullFavoriteArtists(_ artists: [Artist]) {
        let counts = albumCountByArtist()
        weak var weakTemplate: CPListTemplate?
        func makeItems() -> (items: [CPListItem], coverMap: [String: [CPListItem]], coverIds: [String]) {
            var coverMap: [String: [CPListItem]] = [:]
            var coverIds: [String] = []
            let items = artists.map { artist -> CPListItem in
                let count = counts[artist.id] ?? 0
                let item = artistListItem(artist, subtitle: "\(count) \(String(localized: "albums"))") { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openArtist(artist, from: self.interfaceController)
                    Task { @MainActor [weak self] in
                        guard let self, let t = weakTemplate else { return }
                        let (freshItems, freshMap, freshIds) = makeItems()
                        prefillCoversFromCache(freshMap)
                        t.updateSections([CPListSection(items: freshItems, header: nil, sectionIndexTitle: nil)])
                        self.coverLoadTask?.cancel()
                        self.coverLoadTask = Task { await streamCovers(into: freshMap, orderedCoverArtIds: freshIds) }
                    }
                }
                if let id = artist.coverArt {
                    if coverMap[id] == nil { coverIds.append(id) }
                    coverMap[id, default: []].append(item)
                }
                return item
            }
            return (items, coverMap, coverIds)
        }
        let (items, coverMap, coverIds) = makeItems()
        prefillCoversFromCache(coverMap)
        let template = CPListTemplate(title: String(localized: "favorite_artists"), sections: [
            CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        ])
        weakTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)
        guard !coverMap.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task { await streamCovers(into: coverMap, orderedCoverArtIds: coverIds) }
    }

}
