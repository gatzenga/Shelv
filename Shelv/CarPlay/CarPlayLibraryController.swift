import CarPlay
import Combine

@MainActor
final class CarPlayLibraryController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let t = CPListTemplate(title: tr("Library", "Bibliothek"), sections: [])
        t.tabImage = UIImage(systemName: "books.vertical")
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

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { await buildMenu() }
    }

    // MARK: - Top-level Library Menu

    private func buildMenu() async {
        let enableFavorites = UserDefaults.standard.bool(forKey: "enableFavorites")

        let albumsItem = CPListItem(text: tr("Albums", "Alben"), detailText: nil)
        albumsItem.accessoryType = .disclosureIndicator
        albumsItem.setImage((UIImage(systemName: "music.note") ?? UIImage()).withTintColor(.label, renderingMode: .alwaysOriginal))
        albumsItem.handler = { [weak self] _, c in self?.pushAlbumsList(); c() }

        let artistsItem = CPListItem(text: tr("Artists", "Künstler"), detailText: nil)
        artistsItem.accessoryType = .disclosureIndicator
        artistsItem.setImage((UIImage(systemName: "person.2") ?? UIImage()).withTintColor(.label, renderingMode: .alwaysOriginal))
        artistsItem.handler = { [weak self] _, c in self?.pushArtistsList(); c() }

        var items: [CPListItem] = [albumsItem, artistsItem]
        if enableFavorites {
            let favItem = CPListItem(text: tr("Favorites", "Favoriten"), detailText: nil)
            favItem.accessoryType = .disclosureIndicator
            favItem.setImage((UIImage(systemName: "heart") ?? UIImage()).withTintColor(.label, renderingMode: .alwaysOriginal))
            favItem.handler = { [weak self] _, c in self?.pushFavorites(); c() }
            items.append(favItem)
        }

        rootTemplate.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
    }

    // MARK: - Albums List

    private func pushAlbumsList() {
        let albums = displayAlbums()
        var items = albums.map { album -> CPListItem in
            albumListItem(album) { [weak self] _, c in
                guard let self else { c(); return }
                CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                c()
            }
        }

        let template = CPListTemplate(title: tr("Albums", "Alben"), sections: [
            CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        ])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task {
            let pairs = albums.map { (item: CPListItem(text: "", detailText: nil), coverArtId: $0.coverArt) }
            let imageMap = await batchLoadCovers(pairs)
            guard !imageMap.isEmpty else { return }
            items = albums.map { album -> CPListItem in
                let item = albumListItem(album) { [weak self] _, c in
                    guard let self else { c(); return }
                    CarPlayNavigation.openAlbum(album, from: self.interfaceController)
                    c()
                }
                if let id = album.coverArt, let img = imageMap[id] { item.setImage(img) }
                return item
            }
            template.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
        }
    }

    private func displayAlbums() -> [Album] {
        if OfflineModeService.shared.isOffline {
            if LibraryStore.shared.albums.isEmpty {
                return DownloadStore.shared.albums.map { $0.asAlbum() }
            }
            let downloadedIds = Set(DownloadStore.shared.albums.map { $0.albumId })
            return LibraryStore.shared.albums.filter { downloadedIds.contains($0.id) }
        }
        return LibraryStore.shared.albums
    }

    // MARK: - Artists List

    private func pushArtistsList() {
        let artists = displayArtists()
        let albumCounts = buildLocalAlbumCounts()

        var items = artists.map { artist -> CPListItem in
            let count = albumCounts[artist.id] ?? 0
            let subtitle = "\(count) \(tr("albums", "Alben"))"
            return artistListItem(artist, subtitle: subtitle) { [weak self] _, c in
                guard let self else { c(); return }
                CarPlayNavigation.openArtist(artist, from: self.interfaceController)
                c()
            }
        }

        let template = CPListTemplate(title: tr("Artists", "Künstler"), sections: [
            CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        ])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task {
            let pairs = artists.map { (item: CPListItem(text: "", detailText: nil), coverArtId: $0.coverArt) }
            let imageMap = await batchLoadCovers(pairs)
            guard !imageMap.isEmpty else { return }
            items = artists.map { artist -> CPListItem in
                let count = albumCounts[artist.id] ?? 0
                let subtitle = "\(count) \(tr("albums", "Alben"))"
                let item = artistListItem(artist, subtitle: subtitle) { [weak self] _, c in
                    guard let self else { c(); return }
                    CarPlayNavigation.openArtist(artist, from: self.interfaceController)
                    c()
                }
                if let id = artist.coverArt, let img = imageMap[id] { item.setImage(img) }
                return item
            }
            template.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
        }
    }

    private func displayArtists() -> [Artist] {
        if OfflineModeService.shared.isOffline {
            if LibraryStore.shared.artists.isEmpty {
                return DownloadStore.shared.artists.map { $0.asArtist() }
            }
            let downloadedNames = Set(DownloadStore.shared.artists.map { $0.name })
            return LibraryStore.shared.artists.filter { downloadedNames.contains($0.name) }
        }
        return LibraryStore.shared.artists
    }

    private func buildLocalAlbumCounts() -> [String: Int] {
        let source = OfflineModeService.shared.isOffline
            ? DownloadStore.shared.albums.map { $0.asAlbum() }
            : LibraryStore.shared.albums
        return Dictionary(grouping: source, by: { $0.artistId ?? "" }).mapValues { $0.count }
    }

    // MARK: - Favorites

    private func pushFavorites() {
        let songs = displayFavoriteSongs()
        let section = CPListSection(items: songs.enumerated().map { idx, song in
            songListItem(song, index: idx) { _, c in
                AudioPlayerService.shared.play(songs: songs, startIndex: idx); c()
            }
        }, header: nil, sectionIndexTitle: nil)

        let template = CPListTemplate(title: tr("Favorites", "Favoriten"), sections: [section])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func displayFavoriteSongs() -> [Song] {
        let starred = LibraryStore.shared.starredSongs
        if OfflineModeService.shared.isOffline {
            let downloadedIds = Set(DownloadStore.shared.songs.map { $0.songId })
            return starred.filter { downloadedIds.contains($0.id) }
        }
        return starred
    }
}
