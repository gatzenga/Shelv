import CarPlay

@MainActor
final class CarPlaySearchController: NSObject {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate        // CPTabBarTemplate only allows CPListTemplate/CPGridTemplate
    private let searchTemplate: CPSearchTemplate
    private var searchTask: Task<Void, Never>?
    private var lastResults: CarPlaySearchResults = .empty

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        searchTemplate = CPSearchTemplate()
        let tab = CPListTemplate(title: tr("Search", "Suche"), sections: [])
        tab.tabImage = UIImage(systemName: "magnifyingglass")
        rootTemplate = tab
        super.init()
        searchTemplate.delegate = self
        // Push search template when tab is selected (empty list triggers immediate push)
        let searchRow = CPListItem(text: tr("Search…", "Suchen…"), detailText: nil)
        searchRow.setImage(UIImage(systemName: "magnifyingglass")?.withTintColor(.label, renderingMode: .alwaysOriginal) ?? UIImage())
        searchRow.handler = { [weak self] _, c in
            guard let self else { c(); return }
            self.interfaceController.pushTemplate(self.searchTemplate, animated: true, completion: nil)
            c()
        }
        tab.updateSections([CPListSection(items: [searchRow])])
    }

    func cancel() {
        searchTask?.cancel()
    }
}

// MARK: - CPSearchTemplateDelegate

extension CarPlaySearchController: CPSearchTemplateDelegate {
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        searchTask?.cancel()
        guard !searchText.isEmpty else {
            lastResults = .empty
            completionHandler([])
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let (results, items) = await performSearch(query: searchText)
            guard !Task.isCancelled else { return }
            lastResults = results
            completionHandler(items)
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        handleSelection(item: item)
        completionHandler()
    }
}

// MARK: - Search Logic

extension CarPlaySearchController {
    private func performSearch(query: String) async -> (CarPlaySearchResults, [CPListItem]) {
        if OfflineModeService.shared.isOffline {
            return await performOfflineSearch(query: query)
        }
        return await performOnlineSearch(query: query)
    }

    private func performOnlineSearch(query: String) async -> (CarPlaySearchResults, [CPListItem]) {
        async let apiResult = try? SubsonicAPIService.shared.search(query: query)
        async let lyricsResult: [LyricsSearchResult] = {
            guard let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString else { return [] }
            return await LyricsService.shared.searchLyrics(text: query, serverId: serverId)
        }()

        let (api, lyrics) = await (apiResult, lyricsResult)

        let artists   = api?.artist ?? []
        let albums    = api?.album  ?? []
        let songs     = api?.song   ?? []
        let lyricSongs = lyrics.map { item -> Song in
            Song(id: item.songId,
                 title: item.songTitle ?? item.songId,
                 artist: item.artistName, album: nil, albumId: nil,
                 track: nil, duration: item.duration, coverArt: item.coverArt,
                 year: nil, genre: nil, playCount: nil,
                 starred: nil, suffix: nil, bitRate: nil)
        }
        let results = CarPlaySearchResults(artists: artists, albums: albums, songs: songs + lyricSongs)
        return (results, buildItems(results))
    }

    private func performOfflineSearch(query: String) async -> (CarPlaySearchResults, [CPListItem]) {
        guard let sid = SubsonicAPIService.shared.activeServer?.stableId, !sid.isEmpty else {
            return (.empty, [])
        }
        let records = await DownloadDatabase.shared.search(serverId: sid, query: query, limit: 100)
        let songs   = records.map { $0.toDownloadedSong().asSong() }
        let q = query.lowercased()
        let albums  = DownloadStore.shared.albums
            .filter { $0.title.lowercased().contains(q) || $0.artistName.lowercased().contains(q) }
            .map    { $0.asAlbum() }
        let artists = DownloadStore.shared.artists
            .filter { $0.name.lowercased().contains(q) }
            .map    { $0.asArtist() }
        let lyricsSid = SubsonicAPIService.shared.activeServer?.id.uuidString ?? sid
        let lyricResults = await LyricsService.shared.searchLyrics(text: query, serverId: lyricsSid)
        let downloadedIds = Set(DownloadStore.shared.songs.map { $0.songId })
        let lyricSongs = lyricResults
            .filter { downloadedIds.contains($0.songId) }
            .map { item -> Song in
                Song(id: item.songId,
                     title: item.songTitle ?? item.songId,
                     artist: item.artistName, album: nil, albumId: nil,
                     track: nil, duration: item.duration, coverArt: item.coverArt,
                     year: nil, genre: nil, playCount: nil,
                     starred: nil, suffix: nil, bitRate: nil)
            }
        let results = CarPlaySearchResults(artists: artists, albums: albums, songs: songs + lyricSongs)
        return (results, buildItems(results))
    }

    private func buildItems(_ results: CarPlaySearchResults) -> [CPListItem] {
        var items: [CPListItem] = []

        func cachedImage(for id: String?) -> UIImage {
            guard let id else { return cpPlaceholder }
            return ImageCacheService.shared.cachedImage(key: "\(id)_300") ?? cpPlaceholder
        }

        for (idx, artist) in results.artists.enumerated() {
            let item = CPListItem(text: artist.name, detailText: tr("Artist", "Künstler"))
            item.accessoryType = .disclosureIndicator
            item.setImage(cachedImage(for: artist.coverArt))
            item.userInfo = ["type": "artist", "idx": idx]
            items.append(item)
        }
        for (idx, album) in results.albums.enumerated() {
            let item = CPListItem(text: album.name, detailText: album.artist ?? tr("Album", "Album"))
            item.accessoryType = .disclosureIndicator
            item.setImage(cachedImage(for: album.coverArt))
            item.userInfo = ["type": "album", "idx": idx]
            items.append(item)
        }
        for (idx, song) in results.songs.enumerated() {
            let item = CPListItem(text: song.title, detailText: song.artist ?? tr("Song", "Titel"))
            item.setImage(cachedImage(for: song.coverArt))
            item.userInfo = ["type": "song", "idx": idx]
            items.append(item)
        }
        return items
    }

    private func handleSelection(item: CPListItem) {
        guard let info = item.userInfo as? [String: Any],
              let type = info["type"] as? String,
              let idx  = info["idx"]  as? Int else { return }

        switch type {
        case "artist" where lastResults.artists.indices.contains(idx):
            CarPlayNavigation.openArtist(lastResults.artists[idx], from: interfaceController)
        case "album" where lastResults.albums.indices.contains(idx):
            CarPlayNavigation.openAlbum(lastResults.albums[idx], from: interfaceController)
        case "song" where lastResults.songs.indices.contains(idx):
            AudioPlayerService.shared.play(songs: lastResults.songs, startIndex: idx)
        default:
            break
        }
    }
}

// MARK: - Search Result Container

struct CarPlaySearchResults {
    let artists: [Artist]
    let albums:  [Album]
    let songs:   [Song]

    static let empty = CarPlaySearchResults(artists: [], albums: [], songs: [])
}
