import CarPlay
import Combine

@MainActor
final class CarPlayPlaylistsController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var loadTask: Task<Void, Never>?
    private var coverLoadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let t = CPListTemplate(title: String(localized: "playlists"), sections: [])
        t.tabImage = UIImage(systemName: "music.note.list")
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

        LibraryStore.shared.$playlists
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.buildList() }
            .store(in: &cancellables)

        DownloadStore.shared.$offlinePlaylistIds
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard OfflineModeService.shared.isOffline else { return }
                self?.buildOfflineList()
            }
            .store(in: &cancellables)

        // Offline-Start-Fix: buildOfflineList() prüft !DownloadStore.shared.songs.isEmpty.
        // Wenn songs noch nicht geladen sind (async reload nach CarPlay-Connect), zeigt die
        // Liste fälschlicherweise "Keine Offline-Playlists". Dieser Subscriber re-triggert
        // buildOfflineList() sobald songs befüllt werden.
        DownloadStore.shared.$songs
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard OfflineModeService.shared.isOffline else { return }
                self?.buildOfflineList()
            }
            .store(in: &cancellables)

        // Recap-Playlists werden separat im Recap-Tab angezeigt — Liste neu bauen,
        // sobald sich die Menge der Recap-IDs ändert.
        RecapStore.shared.$recapPlaylistIds
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        // DownloadStore räumt offlinePlaylistIds jetzt selbst in reload() auf — der
        // direkte $offlinePlaylistIds-Subscriber oben deckt den Delete-All-Pfad mit ab.

        reload()
    }

    func cancel() {
        loadTask?.cancel()
        coverLoadTask?.cancel()
        cancellables.removeAll()
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task {
            if OfflineModeService.shared.isOffline {
                buildOfflineList()
            } else {
                await LibraryStore.shared.loadPlaylists()
                buildList()
            }
        }
    }

    private func buildList() {
        // Defensive: wenn offline, nie die volle Liste — auch wenn dieser Pfad aus einer
        // LibraryStore-Subscription gerufen wurde. Sonst kann ein verspäteter Subscriber
        // die "No offline playlists"-Anzeige überschreiben.
        if OfflineModeService.shared.isOffline {
            buildOfflineList()
            return
        }
        let recapIds = UserDefaults.standard.bool(forKey: "recapEnabled")
            ? RecapStore.shared.recapPlaylistIds
            : []
        let playlists = LibraryStore.shared.playlists.filter { !recapIds.contains($0.id) }
        if playlists.isEmpty {
            let empty = CPListItem(text: String(localized: "no_playlists"), detailText: nil)
            rootTemplate.updateSections([CPListSection(items: [empty])])
            return
        }
        showPlaylists(playlists)
    }

    private func buildOfflineList() {
        let offlineIds = DownloadStore.shared.offlinePlaylistIds
        let recapIds = UserDefaults.standard.bool(forKey: "recapEnabled")
            ? RecapStore.shared.recapPlaylistIds
            : []
        let hasDownloads = !DownloadStore.shared.songs.isEmpty
        // Falls lokale Daten extern oder während einer Migration verschwinden, keine
        // Offline-Playlist anbieten, die nicht mehr abgespielt werden kann.
        let playlists: [Playlist] = hasDownloads
            ? LibraryStore.shared.playlists.filter { offlineIds.contains($0.id) && !recapIds.contains($0.id) }
            : []
        if playlists.isEmpty {
            let empty = CPListItem(text: String(localized: "no_offline_playlists"), detailText: nil)
            rootTemplate.updateSections([CPListSection(items: [empty])])
            return
        }
        showPlaylists(playlists)
    }

    private func showPlaylists(_ playlists: [Playlist]) {
        func makeItems() -> (items: [CPListItem], coverMap: [String: [CPListItem]]) {
            var coverMap: [String: [CPListItem]] = [:]
            let items = playlists.map { playlist -> CPListItem in
                let item = playlistListItem(playlist) { [weak self] _, c in
                    guard let self else { c(); return }
                    c()
                    CarPlayNavigation.openPlaylist(playlist, from: self.interfaceController)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let (freshItems, freshMap) = makeItems()
                        prefillCoversFromCache(freshMap)
                        self.rootTemplate.updateSections([CPListSection(items: freshItems, header: nil, sectionIndexTitle: nil)])
                        self.coverLoadTask?.cancel()
                        self.coverLoadTask = Task { await streamCovers(into: freshMap) }
                    }
                }
                if let id = playlist.coverArt { coverMap[id, default: []].append(item) }
                return item
            }
            return (items, coverMap)
        }
        let (items, coverMap) = makeItems()
        prefillCoversFromCache(coverMap)
        rootTemplate.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
        guard !coverMap.isEmpty else { return }
        coverLoadTask?.cancel()
        coverLoadTask = Task { await streamCovers(into: coverMap) }
    }
}
