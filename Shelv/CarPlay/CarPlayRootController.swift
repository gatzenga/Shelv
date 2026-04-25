import CarPlay
import Combine

@MainActor
final class CarPlayRootController {
    private let interfaceController: CPInterfaceController
    private var discoverController: CarPlayDiscoverController?
    private var libraryController: CarPlayLibraryController?
    private var playlistsController: CarPlayPlaylistsController?
    private var searchController: CarPlaySearchController?

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func connect() {
        let discover  = CarPlayDiscoverController(interfaceController: interfaceController)
        let library   = CarPlayLibraryController(interfaceController: interfaceController)
        let playlists = CarPlayPlaylistsController(interfaceController: interfaceController)
        let search    = CarPlaySearchController(interfaceController: interfaceController)

        discoverController  = discover
        libraryController   = library
        playlistsController = playlists
        searchController    = search

        let tabBar = CPTabBarTemplate(templates: [
            discover.rootTemplate,
            library.rootTemplate,
            playlists.rootTemplate,
            search.rootTemplate,
        ])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        discover.load()
        library.load()
        playlists.load()
    }

    func disconnect() {
        discoverController?.cancel()
        libraryController?.cancel()
        playlistsController?.cancel()
        searchController?.cancel()
        discoverController  = nil
        libraryController   = nil
        playlistsController = nil
        searchController    = nil
    }
}
