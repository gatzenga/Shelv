import CarPlay
import Combine

@MainActor
final class CarPlayPlaylistsController {
    private let interfaceController: CPInterfaceController
    let rootTemplate: CPListTemplate
    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let t = CPListTemplate(title: tr("Playlists", "Playlists"), sections: [])
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

        reload()
    }

    func cancel() {
        loadTask?.cancel()
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
        let playlists = LibraryStore.shared.playlists
        if playlists.isEmpty {
            let empty = CPListItem(text: tr("No playlists", "Keine Playlists"), detailText: nil)
            rootTemplate.updateSections([CPListSection(items: [empty])])
            return
        }
        let items = playlists.map { playlist in
            playlistListItem(playlist) { [weak self] _, c in
                guard let self else { c(); return }
                CarPlayNavigation.openPlaylist(playlist, from: self.interfaceController)
                c()
            }
        }
        rootTemplate.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
    }

    private func buildOfflineList() {
        let offlineIds = DownloadStore.shared.offlinePlaylistIds
        let playlists = LibraryStore.shared.playlists.filter { offlineIds.contains($0.id) }
        if playlists.isEmpty {
            let empty = CPListItem(text: tr("No offline playlists", "Keine Offline-Playlists"), detailText: nil)
            rootTemplate.updateSections([CPListSection(items: [empty])])
            return
        }
        let items = playlists.map { playlist in
            playlistListItem(playlist) { [weak self] _, c in
                guard let self else { c(); return }
                CarPlayNavigation.openPlaylist(playlist, from: self.interfaceController)
                c()
            }
        }
        rootTemplate.updateSections([CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
    }
}
