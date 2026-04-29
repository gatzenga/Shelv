import CarPlay
import Combine

private let kPreviewCount = 4

@MainActor
final class CarPlayLibraryController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var cancellables = Set<AnyCancellable>()
    // Eigene Task-Variable pro Screen — verhindert gegenseitiges Canceln (Szenario B)
    private var albumCoverTask: Task<Void, Never>?
    private var artistCoverTask: Task<Void, Never>?
    private var coverLoadTask: Task<Void, Never>?
    private var lastEnableFavorites: Bool = UserDefaults.standard.bool(forKey: "enableFavorites")
    private var lastThemeColor: String = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
    private weak var albumsTemplate: CPListTemplate?
    private weak var artistsTemplate: CPListTemplate?
    private weak var favoritesTemplate: CPListTemplate?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let isOffline = OfflineModeService.shared.isOffline
        let title = isOffline ? tr("Downloads", "Downloads") : tr("Library", "Bibliothek")
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
                let currentFav   = UserDefaults.standard.bool(forKey: "enableFavorites")
                let currentTheme = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                if currentFav != self.lastEnableFavorites {
                    self.lastEnableFavorites = currentFav
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

        buildMenu()
    }

    func cancel() {
        albumCoverTask?.cancel()
        artistCoverTask?.cancel()
        coverLoadTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Menu

    private func buildMenu() {
        let isOffline = OfflineModeService.shared.isOffline

        // Tab-Titel und -Icon reaktiv aktualisieren (tabTitle ist auf CPTemplate nachträglich settable)
        rootTemplate.tabTitle = isOffline ? tr("Downloads", "Downloads") : tr("Library", "Bibliothek")
        rootTemplate.tabImage = UIImage(systemName: isOffline ? "internaldrive" : "books.vertical")

        var items: [CPListItem] = [
            menuListItem(title: tr("Albums", "Alben"), systemImage: "square.stack") { [weak self] _, c in
                c(); self?.pushAlbumsList()
            },
            menuListItem(title: tr("Artists", "Künstler"), systemImage: "music.microphone") { [weak self] _, c in
                c(); self?.pushArtistsList()
            },
        ]
        if UserDefaults.standard.bool(forKey: "enableFavorites") {
            items.append(menuListItem(title: tr("Favorites", "Favoriten"), systemImage: "heart") { [weak self] _, c in
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
            let built = self.makeAlbumSections(current)
            prefillCoversFromCache(built.itemsByCoverId)
            t.updateSections(built.sections)
            self.albumCoverTask?.cancel()
            self.albumCoverTask = Task { await streamCovers(into: built.itemsByCoverId) }
        }
    }

    private func rebuildArtistsTemplate() {
        Task { @MainActor [weak self] in
            guard let self, let t = self.artistsTemplate else { return }
            let current = self.artistSource()
            let counts = self.albumCountByArtist()
            let built = self.makeArtistSections(current, counts: counts)
            prefillCoversFromCache(built.itemsByCoverId)
            t.updateSections(built.sections)
            self.artistCoverTask?.cancel()
            self.artistCoverTask = Task { await streamCovers(into: built.itemsByCoverId) }
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
            self.coverLoadTask = Task { await streamCovers(into: built.itemsByCoverId) }
        }
    }

    private func pushAlbumsList() {
        let placeholder = CPListItem(text: tr("Loading…", "Wird geladen…"), detailText: nil)
        let template = CPListTemplate(title: tr("Albums", "Alben"), sections: [
            CPListSection(items: [placeholder], header: nil, sectionIndexTitle: nil)
        ])
        albumsTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)

        // Eigene Task-Variable — cancelt NUR einen früheren Album-Task, nie Artists
        albumCoverTask?.cancel()
        albumCoverTask = Task { [weak self] in
            guard let self else { return }
            // Gecachte Daten sofort anzeigen, dann vollständig von der API nachladen.
            // Items werden EINMAL erstellt; Covers mutieren die Items per setImage in-place,
            // damit Tap-Handler stabil bleiben und CarPlay keine IPC-Storms abbekommt.
            var current = self.albumSource()
            var built = self.makeAlbumSections(current)
            // Loading-Placeholder nur ersetzen wenn wir wirklich Inhalt zu zeigen haben.
            if !current.isEmpty {
                template.updateSections(built.sections)
            }

            if !OfflineModeService.shared.isOffline {
                await LibraryStore.shared.loadAlbums(sortBy: "alphabeticalByName")
                let fresh = self.albumSource()
                if fresh.map(\.id) != current.map(\.id) {
                    current = fresh
                    built = self.makeAlbumSections(current)
                    template.updateSections(built.sections)
                }
            }
            await streamCovers(into: built.itemsByCoverId)
        }
    }

    private func makeAlbumSections(_ albums: [Album]) -> (sections: [CPListSection], itemsByCoverId: [String: [CPListItem]]) {
        let sorted = albums.sorted {
            stripArticle($0.name).localizedStandardCompare(stripArticle($1.name)) == .orderedAscending
        }
        let grouped = Dictionary(grouping: sorted) { firstSortLetter($0.name) }
        let letters = grouped.keys.sorted()
        let cap = max(20, CPListTemplate.maximumItemCount / max(1, letters.count))
        var itemsByCoverId: [String: [CPListItem]] = [:]
        var sections: [CPListSection] = []
        for letter in letters {
            var letterItems: [CPListItem] = []
            for album in (grouped[letter] ?? []).prefix(cap) {
                let item = albumListItem(album) { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                    self.rebuildAlbumsTemplate()
                }
                if let id = album.coverArt {
                    itemsByCoverId[id, default: []].append(item)
                }
                letterItems.append(item)
            }
            sections.append(CPListSection(items: letterItems, header: letter, sectionIndexTitle: letter))
        }
        return (sections, itemsByCoverId)
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
        let placeholder = CPListItem(text: tr("Loading…", "Wird geladen…"), detailText: nil)
        let template = CPListTemplate(title: tr("Artists", "Künstler"), sections: [
            CPListSection(items: [placeholder], header: nil, sectionIndexTitle: nil)
        ])
        artistsTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)

        // Eigene Task-Variable — cancelt NUR einen früheren Artists-Task, nie Albums
        artistCoverTask?.cancel()
        artistCoverTask = Task { [weak self] in
            guard let self else { return }
            var current = self.artistSource()
            var counts = self.albumCountByArtist()
            var built = self.makeArtistSections(current, counts: counts)
            if !current.isEmpty {
                template.updateSections(built.sections)
            }

            if current.isEmpty && !OfflineModeService.shared.isOffline {
                await LibraryStore.shared.loadArtists()
                let fresh = self.artistSource()
                if fresh.map(\.id) != current.map(\.id) {
                    current = fresh
                    counts = self.albumCountByArtist()
                    built = self.makeArtistSections(current, counts: counts)
                    template.updateSections(built.sections)
                }
            }
            await streamCovers(into: built.itemsByCoverId)
        }
    }

    private func makeArtistSections(_ artists: [Artist], counts: [String: Int]) -> (sections: [CPListSection], itemsByCoverId: [String: [CPListItem]]) {
        let sorted = artists.sorted {
            stripArticle($0.name).localizedStandardCompare(stripArticle($1.name)) == .orderedAscending
        }
        let grouped = Dictionary(grouping: sorted) { firstSortLetter($0.name) }
        let letters = grouped.keys.sorted()
        let cap = max(20, CPListTemplate.maximumItemCount / max(1, letters.count))
        var itemsByCoverId: [String: [CPListItem]] = [:]
        var sections: [CPListSection] = []
        for letter in letters {
            var letterItems: [CPListItem] = []
            for artist in (grouped[letter] ?? []).prefix(cap) {
                let count = counts[artist.id] ?? 0
                let item = artistListItem(artist, subtitle: "\(count) \(tr("albums", "Alben"))") { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openArtist(artist, from: self.interfaceController)
                    self.rebuildArtistsTemplate()
                }
                if let id = artist.coverArt {
                    itemsByCoverId[id, default: []].append(item)
                }
                letterItems.append(item)
            }
            sections.append(CPListSection(items: letterItems, header: letter, sectionIndexTitle: letter))
        }
        return (sections, itemsByCoverId)
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

    // MARK: - Favorites

    private func pushFavorites() {
        let songs   = starredSongs()
        let albums  = starredAlbums()
        let artists = starredArtists()
        let counts  = albumCountByArtist()

        let template = CPListTemplate(title: tr("Favorites", "Favoriten"), sections: [])
        favoritesTemplate = template
        let built = makeFavoriteSections(songs: songs, albums: albums, artists: artists, counts: counts)
        prefillCoversFromCache(built.itemsByCoverId)
        template.updateSections(built.sections)
        CarPlayNavigation.safePush(template, on: interfaceController)

        // Wenn starredSongs noch nicht geladen — eigenständiger Task, unabhängig von coverLoadTask.
        // $starredSongs subscriber baut Template automatisch neu wenn loadStarred fertig ist.
        if LibraryStore.shared.starredSongs.isEmpty {
            Task { await LibraryStore.shared.loadStarred() }
        }

        guard !built.itemsByCoverId.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task { await streamCovers(into: built.itemsByCoverId) }
    }

    private func makeFavoriteSections(
        songs: [Song], albums: [Album], artists: [Artist],
        counts: [String: Int]
    ) -> (sections: [CPListSection], itemsByCoverId: [String: [CPListItem]]) {
        var sections: [CPListSection] = []
        var itemsByCoverId: [String: [CPListItem]] = [:]

        if !songs.isEmpty {
            var items: [CPListItem] = Array(songs.prefix(kPreviewCount)).enumerated().map { idx, song in
                songListItem(song, index: idx) { [weak self] _, c in
                    c()
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx)
                    if let self { CarPlayNavigation.presentNowPlaying(on: self.interfaceController) }
                    self?.rebuildFavoritesTemplate()
                }
            }
            if songs.count > kPreviewCount {
                items.append(showAllListItem(title: tr("Show All (\(songs.count))", "Alle anzeigen (\(songs.count))")) { [weak self] _, c in
                    c(); self?.pushFullFavoriteSongs(songs)
                })
            }
            sections.append(CPListSection(items: items, header: tr("Songs", "Titel"), sectionIndexTitle: nil))
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
                if let id = album.coverArt {
                    itemsByCoverId[id, default: []].append(item)
                }
                items.append(item)
            }
            if albums.count > kPreviewCount {
                items.append(showAllListItem(title: tr("Show All (\(albums.count))", "Alle anzeigen (\(albums.count))")) { [weak self] _, c in
                    c(); self?.pushFullFavoriteAlbums(albums)
                })
            }
            sections.append(CPListSection(items: items, header: tr("Albums", "Alben"), sectionIndexTitle: nil))
        }

        if !artists.isEmpty {
            var items: [CPListItem] = []
            for artist in artists.prefix(kPreviewCount) {
                let count = counts[artist.id] ?? 0
                let item = artistListItem(artist, subtitle: "\(count) \(tr("albums", "Alben"))") { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openArtist(artist, from: self.interfaceController)
                    self.rebuildFavoritesTemplate()
                }
                if let id = artist.coverArt {
                    itemsByCoverId[id, default: []].append(item)
                }
                items.append(item)
            }
            if artists.count > kPreviewCount {
                items.append(showAllListItem(title: tr("Show All (\(artists.count))", "Alle anzeigen (\(artists.count))")) { [weak self] _, c in
                    c(); self?.pushFullFavoriteArtists(artists)
                })
            }
            sections.append(CPListSection(items: items, header: tr("Artists", "Künstler"), sectionIndexTitle: nil))
        }

        if sections.isEmpty {
            let empty = CPListItem(text: tr("No favorites yet", "Noch keine Favoriten"), detailText: nil)
            sections = [CPListSection(items: [empty], header: nil, sectionIndexTitle: nil)]
        }
        return (sections, itemsByCoverId)
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
        func makeSongsSection() -> CPListSection {
            let items = songs.enumerated().map { idx, song in
                songListItem(song, index: idx) { [weak self] _, c in
                    c()
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx)
                    if let self { CarPlayNavigation.presentNowPlaying(on: self.interfaceController) }
                    Task { @MainActor in
                        weakTemplate?.updateSections([CPListSection(items: makeSongsSection().items, header: nil, sectionIndexTitle: nil)])
                    }
                }
            }
            return CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        }
        let template = CPListTemplate(title: tr("Favorite Songs", "Lieblingstitel"), sections: [makeSongsSection()])
        weakTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)
    }

    private func pushFullFavoriteAlbums(_ albums: [Album]) {
        weak var weakTemplate: CPListTemplate?
        func makeItems() -> (items: [CPListItem], coverMap: [String: [CPListItem]]) {
            var coverMap: [String: [CPListItem]] = [:]
            let items = albums.map { album -> CPListItem in
                let item = albumListItem(album) { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                    Task { @MainActor [weak self] in
                        guard let self, let t = weakTemplate else { return }
                        let (freshItems, freshMap) = makeItems()
                        prefillCoversFromCache(freshMap)
                        t.updateSections([CPListSection(items: freshItems, header: nil, sectionIndexTitle: nil)])
                        self.coverLoadTask?.cancel()
                        self.coverLoadTask = Task { await streamCovers(into: freshMap) }
                    }
                }
                if let id = album.coverArt { coverMap[id, default: []].append(item) }
                return item
            }
            return (items, coverMap)
        }
        let (items, coverMap) = makeItems()
        let template = CPListTemplate(title: tr("Favorite Albums", "Lieblingsalben"), sections: [
            CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        ])
        weakTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)
        guard !coverMap.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task { await streamCovers(into: coverMap) }
    }

    private func pushFullFavoriteArtists(_ artists: [Artist]) {
        let counts = albumCountByArtist()
        weak var weakTemplate: CPListTemplate?
        func makeItems() -> (items: [CPListItem], coverMap: [String: [CPListItem]]) {
            var coverMap: [String: [CPListItem]] = [:]
            let items = artists.map { artist -> CPListItem in
                let count = counts[artist.id] ?? 0
                let item = artistListItem(artist, subtitle: "\(count) \(tr("albums", "Alben"))") { [weak self] _, c in
                    c()
                    guard let self else { return }
                    CarPlayNavigation.openArtist(artist, from: self.interfaceController)
                    Task { @MainActor [weak self] in
                        guard let self, let t = weakTemplate else { return }
                        let (freshItems, freshMap) = makeItems()
                        prefillCoversFromCache(freshMap)
                        t.updateSections([CPListSection(items: freshItems, header: nil, sectionIndexTitle: nil)])
                        self.coverLoadTask?.cancel()
                        self.coverLoadTask = Task { await streamCovers(into: freshMap) }
                    }
                }
                if let id = artist.coverArt { coverMap[id, default: []].append(item) }
                return item
            }
            return (items, coverMap)
        }
        let (items, coverMap) = makeItems()
        let template = CPListTemplate(title: tr("Favorite Artists", "Lieblingskünstler"), sections: [
            CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        ])
        weakTemplate = template
        CarPlayNavigation.safePush(template, on: interfaceController)
        guard !coverMap.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task { await streamCovers(into: coverMap) }
    }

}
