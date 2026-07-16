import CarPlay
import Combine

@MainActor
final class CarPlayPlaylistsController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var loadTask: Task<Void, Never>?
    private var coverLoadTask: Task<Void, Never>?
    private var folderCoverLoadTasks: [String: Task<Void, Never>] = [:]
    private var folderTemplates: [String: CPListTemplate] = [:]
    private var playlistTree: [PlaylistTreeNode] = []
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
        folderCoverLoadTasks.values.forEach { $0.cancel() }
        folderCoverLoadTasks.removeAll()
        folderTemplates.removeAll()
        playlistTree.removeAll()
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
        playlistTree = PlaylistTreeNode.make(from: playlists)
        rebuildTemplate(rootTemplate, nodes: playlistTree, folderID: nil)

        for (folderID, template) in folderTemplates {
            guard let folder = findFolder(id: folderID, in: playlistTree) else {
                template.updateSections([])
                continue
            }
            rebuildTemplate(template, nodes: folder.children ?? [], folderID: folderID)
        }
    }

    private func rebuildTemplate(
        _ template: CPListTemplate,
        nodes: [PlaylistTreeNode],
        folderID: String?
    ) {
        var coverMap: [String: [CPListItem]] = [:]
        let items = nodes.map { node -> CPListItem in
            if let playlist = node.playlist {
                let item = playlistListItem(playlist, displayName: node.title) { [weak self, weak template] _, completion in
                    guard let self else { completion(); return }
                    completion()
                    CarPlayNavigation.openPlaylist(playlist, from: self.interfaceController)
                    guard let template else { return }
                    self.rebuildTemplate(template, nodes: nodes, folderID: folderID)
                }
                if let coverArt = playlist.coverArt {
                    coverMap[coverArt, default: []].append(item)
                }
                return item
            }

            let detail = "\(node.playlistCount) \(String(localized: "playlists"))"
            let item = CPListItem(
                text: node.title,
                detailText: detail,
                image: cpListIcon("folder.fill"),
                accessoryImage: nil,
                accessoryType: .disclosureIndicator
            )
            item.handler = { [weak self, weak template] _, completion in
                guard let self else { completion(); return }
                completion()
                self.openFolder(node)
                guard let template else { return }
                self.rebuildTemplate(template, nodes: nodes, folderID: folderID)
            }
            return item
        }

        prefillCoversFromCache(coverMap)
        template.updateSections([
            CPListSection(items: items, header: nil, sectionIndexTitle: nil)
        ])
        startCoverLoading(coverMap, folderID: folderID)
    }

    private func openFolder(_ folder: PlaylistTreeNode) {
        let template: CPListTemplate
        if let existing = folderTemplates[folder.id] {
            template = existing
        } else {
            template = CPListTemplate(title: folder.title, sections: [])
            folderTemplates[folder.id] = template
        }
        rebuildTemplate(template, nodes: folder.children ?? [], folderID: folder.id)
        CarPlayNavigation.safePush(template, on: interfaceController)
    }

    private func startCoverLoading(
        _ coverMap: [String: [CPListItem]],
        folderID: String?
    ) {
        if let folderID {
            folderCoverLoadTasks[folderID]?.cancel()
            guard !coverMap.isEmpty else {
                folderCoverLoadTasks.removeValue(forKey: folderID)
                return
            }
            folderCoverLoadTasks[folderID] = Task { await streamCovers(into: coverMap) }
        } else {
            coverLoadTask?.cancel()
            guard !coverMap.isEmpty else {
                coverLoadTask = nil
                return
            }
            coverLoadTask = Task { await streamCovers(into: coverMap) }
        }
    }

    private func findFolder(
        id: String,
        in nodes: [PlaylistTreeNode]
    ) -> PlaylistTreeNode? {
        for node in nodes {
            if node.id == id, node.isFolder { return node }
            if let children = node.children,
               let match = findFolder(id: id, in: children) {
                return match
            }
        }
        return nil
    }
}
