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
    private var coverLoadTask: Task<Void, Never>?   // für Favorites und Full-Lists
    private var lastEnableFavorites: Bool = UserDefaults.standard.bool(forKey: "enableFavorites")

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
                let current = UserDefaults.standard.bool(forKey: "enableFavorites")
                guard current != self.lastEnableFavorites else { return }
                self.lastEnableFavorites = current
                self.buildMenu()
            }
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
                self?.pushAlbumsList(); c()
            },
            menuListItem(title: tr("Artists", "Künstler"), systemImage: "music.microphone") { [weak self] _, c in
                self?.pushArtistsList(); c()
            },
        ]
        if UserDefaults.standard.bool(forKey: "enableFavorites") {
            items.append(menuListItem(title: tr("Favorites", "Favoriten"), systemImage: "heart") { [weak self] _, c in
                self?.pushFavorites(); c()
            })
        }
        rootTemplate.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
    }

    // MARK: - Albums (alphabetische Abschnitte + Buchstabenleiste)

    private func pushAlbumsList() {
        let placeholder = CPListItem(text: tr("Loading…", "Wird geladen…"), detailText: nil)
        let template = CPListTemplate(title: tr("Albums", "Alben"), sections: [
            CPListSection(items: [placeholder], header: nil, sectionIndexTitle: nil)
        ])
        CarPlayNavigation.safePush(template, on: interfaceController)

        // Eigene Task-Variable — cancelt NUR einen früheren Album-Task, nie Artists
        albumCoverTask?.cancel()
        albumCoverTask = Task { [weak self] in
            guard let self else { return }
            // Gecachte Daten sofort anzeigen, dann vollständig von der API nachladen
            let cached = self.albumSource()
            if !cached.isEmpty {
                template.updateSections(self.albumSections(cached))
            }
            if !OfflineModeService.shared.isOffline {
                await LibraryStore.shared.loadAlbums(sortBy: "alphabeticalByName")
            }
            let albums = self.albumSource()
            template.updateSections(self.albumSections(albums))
            await applyCoversAsync(template: template, coverArtIds: albums.map { $0.coverArt }) { [weak self] map in
                self?.albumSections(albums, imageMap: map) ?? []
            }
        }
    }

    private func albumSections(_ albums: [Album], imageMap: [String: UIImage] = [:]) -> [CPListSection] {
        let sorted = albums.sorted {
            stripArticle($0.name).localizedStandardCompare(stripArticle($1.name)) == .orderedAscending
        }
        let grouped = Dictionary(grouping: sorted) { firstSortLetter($0.name) }
        let letters = grouped.keys.sorted()
        let cap = max(20, CPListTemplate.maximumItemCount / max(1, letters.count))
        return letters.map { letter in
            let items = (grouped[letter] ?? []).prefix(cap).map { album -> CPListItem in
                let item = albumListItem(album) { [weak self] _, c in
                    guard let self else { c(); return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController); c()
                }
                if let id = album.coverArt, let img = imageMap[id] { item.setImage(img) }
                return item
            }
            return CPListSection(items: Array(items), header: letter, sectionIndexTitle: letter)
        }
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
        CarPlayNavigation.safePush(template, on: interfaceController)

        // Eigene Task-Variable — cancelt NUR einen früheren Artists-Task, nie Albums
        artistCoverTask?.cancel()
        artistCoverTask = Task { [weak self] in
            guard let self else { return }
            // Gecachte Daten sofort anzeigen — erspart die ~2 s Wait-on-API beim ersten Tap.
            let cached = self.artistSource()
            let cachedCounts = self.albumCountByArtist()
            if !cached.isEmpty {
                template.updateSections(self.artistSections(cached, counts: cachedCounts))
            }
            if cached.isEmpty && !OfflineModeService.shared.isOffline {
                await LibraryStore.shared.loadArtists()
            }
            let artists = self.artistSource()
            let counts  = self.albumCountByArtist()
            template.updateSections(self.artistSections(artists, counts: counts))
            await applyCoversAsync(template: template, coverArtIds: artists.map { $0.coverArt }) { [weak self] map in
                self?.artistSections(artists, counts: counts, imageMap: map) ?? []
            }
        }
    }

    private func artistSections(_ artists: [Artist], counts: [String: Int], imageMap: [String: UIImage] = [:]) -> [CPListSection] {
        let sorted = artists.sorted {
            stripArticle($0.name).localizedStandardCompare(stripArticle($1.name)) == .orderedAscending
        }
        let grouped = Dictionary(grouping: sorted) { firstSortLetter($0.name) }
        let letters = grouped.keys.sorted()
        let cap = max(20, CPListTemplate.maximumItemCount / max(1, letters.count))
        return letters.map { letter in
            let items = (grouped[letter] ?? []).prefix(cap).map { artist -> CPListItem in
                let count = counts[artist.id] ?? 0
                let item = artistListItem(artist, subtitle: "\(count) \(tr("albums", "Alben"))") { [weak self] _, c in
                    guard let self else { c(); return }
                    CarPlayNavigation.openArtist(artist, from: self.interfaceController); c()
                }
                if let id = artist.coverArt, let img = imageMap[id] { item.setImage(img) }
                return item
            }
            return CPListSection(items: Array(items), header: letter, sectionIndexTitle: letter)
        }
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
        template.updateSections(favoriteSections(songs: songs, albums: albums, artists: artists, counts: counts))
        CarPlayNavigation.safePush(template, on: interfaceController)

        guard !albums.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task { [weak self] in
            await applyCoversAsync(template: template, coverArtIds: albums.map { $0.coverArt }) { [weak self] map in
                self?.favoriteSections(songs: songs, albums: albums, artists: artists, counts: counts, albumImageMap: map) ?? []
            }
        }
    }

    private func favoriteSections(
        songs: [Song], albums: [Album], artists: [Artist],
        counts: [String: Int], albumImageMap: [String: UIImage] = [:]
    ) -> [CPListSection] {
        var sections: [CPListSection] = []

        if !songs.isEmpty {
            var items: [CPListItem] = Array(songs.prefix(kPreviewCount)).enumerated().map { idx, song in
                songListItem(song, index: idx) { _, c in
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx); c()
                }
            }
            if songs.count > kPreviewCount {
                items.append(showAllListItem(title: tr("Show All (\(songs.count))", "Alle anzeigen (\(songs.count))")) { [weak self] _, c in
                    self?.pushFullFavoriteSongs(songs); c()
                })
            }
            sections.append(CPListSection(items: items, header: tr("Songs", "Titel"), sectionIndexTitle: nil))
        }

        if !albums.isEmpty {
            var items: [CPListItem] = Array(albums.prefix(kPreviewCount)).map { album -> CPListItem in
                let item = albumListItem(album) { [weak self] _, c in
                    guard let self else { c(); return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController); c()
                }
                if let id = album.coverArt, let img = albumImageMap[id] { item.setImage(img) }
                return item
            }
            if albums.count > kPreviewCount {
                items.append(showAllListItem(title: tr("Show All (\(albums.count))", "Alle anzeigen (\(albums.count))")) { [weak self] _, c in
                    self?.pushFullFavoriteAlbums(albums); c()
                })
            }
            sections.append(CPListSection(items: items, header: tr("Albums", "Alben"), sectionIndexTitle: nil))
        }

        if !artists.isEmpty {
            var items: [CPListItem] = Array(artists.prefix(kPreviewCount)).map { artist -> CPListItem in
                let count = counts[artist.id] ?? 0
                return artistListItem(artist, subtitle: "\(count) \(tr("albums", "Alben"))") { [weak self] _, c in
                    guard let self else { c(); return }
                    CarPlayNavigation.openArtist(artist, from: self.interfaceController); c()
                }
            }
            if artists.count > kPreviewCount {
                items.append(showAllListItem(title: tr("Show All (\(artists.count))", "Alle anzeigen (\(artists.count))")) { [weak self] _, c in
                    self?.pushFullFavoriteArtists(artists); c()
                })
            }
            sections.append(CPListSection(items: items, header: tr("Artists", "Künstler"), sectionIndexTitle: nil))
        }

        if sections.isEmpty {
            let empty = CPListItem(text: tr("No favorites yet", "Noch keine Favoriten"), detailText: nil)
            return [CPListSection(items: [empty], header: nil, sectionIndexTitle: nil)]
        }
        return sections
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
        let items = songs.enumerated().map { idx, song in
            songListItem(song, index: idx) { _, c in
                AudioPlayerService.shared.play(songs: songs, startIndex: idx); c()
            }
        }
        let template = CPListTemplate(title: tr("Favorite Songs", "Lieblingstitel"), sections: [
            CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        ])
        CarPlayNavigation.safePush(template, on: interfaceController)
    }

    private func pushFullFavoriteAlbums(_ albums: [Album]) {
        let template = CPListTemplate(title: tr("Favorite Albums", "Lieblingsalben"), sections: [
            CPListSection(items: makeAlbumItems(albums, imageMap: [:]), header: nil, sectionIndexTitle: nil)
        ])
        CarPlayNavigation.safePush(template, on: interfaceController)
        coverLoadTask?.cancel()
        coverLoadTask = Task { [weak self] in
            await applyCoversAsync(template: template, coverArtIds: albums.map { $0.coverArt }) { [weak self] map in
                guard let self else { return [] }
                return [CPListSection(items: self.makeAlbumItems(albums, imageMap: map), header: nil, sectionIndexTitle: nil)]
            }
        }
    }

    private func pushFullFavoriteArtists(_ artists: [Artist]) {
        let counts = albumCountByArtist()
        let template = CPListTemplate(title: tr("Favorite Artists", "Lieblingskünstler"), sections: [
            CPListSection(items: makeArtistItems(artists, counts: counts, imageMap: [:]), header: nil, sectionIndexTitle: nil)
        ])
        CarPlayNavigation.safePush(template, on: interfaceController)
        coverLoadTask?.cancel()
        coverLoadTask = Task { [weak self] in
            await applyCoversAsync(template: template, coverArtIds: artists.map { $0.coverArt }) { [weak self] map in
                guard let self else { return [] }
                return [CPListSection(items: self.makeArtistItems(artists, counts: counts, imageMap: map), header: nil, sectionIndexTitle: nil)]
            }
        }
    }

    // MARK: - Item Builders

    private func makeAlbumItems(_ albums: [Album], imageMap: [String: UIImage]) -> [CPListItem] {
        albums.map { album -> CPListItem in
            let item = albumListItem(album) { [weak self] _, c in
                guard let self else { c(); return }
                CarPlayNavigation.openAlbum(album, from: self.interfaceController); c()
            }
            if let id = album.coverArt, let img = imageMap[id] { item.setImage(img) }
            return item
        }
    }

    private func makeArtistItems(_ artists: [Artist], counts: [String: Int], imageMap: [String: UIImage]) -> [CPListItem] {
        artists.map { artist -> CPListItem in
            let count = counts[artist.id] ?? 0
            let item = artistListItem(artist, subtitle: "\(count) \(tr("albums", "Alben"))") { [weak self] _, c in
                guard let self else { c(); return }
                CarPlayNavigation.openArtist(artist, from: self.interfaceController); c()
            }
            if let id = artist.coverArt, let img = imageMap[id] { item.setImage(img) }
            return item
        }
    }
}
