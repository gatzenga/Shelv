import CarPlay
import Combine

@MainActor
final class CarPlayRootController: NSObject {
    private let interfaceController: CPInterfaceController
    private var discoverController:  CarPlayDiscoverController?
    private var libraryController:   CarPlayLibraryController?
    private var playlistsController: CarPlayPlaylistsController?
    private var recapController:     CarPlayRecapController?
    private var queueController:     CarPlayQueueController?
    private var tabBar: CPTabBarTemplate?
    private var cancellables = Set<AnyCancellable>()
    private var lastRecapEnabled: Bool = UserDefaults.standard.bool(forKey: "recapEnabled")
    private var lastRecapTabVisible: Bool = false

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func connect() {
        let discover  = CarPlayDiscoverController(interfaceController: interfaceController)
        let library   = CarPlayLibraryController(interfaceController: interfaceController)
        let playlists = CarPlayPlaylistsController(interfaceController: interfaceController)
        let recap     = CarPlayRecapController(interfaceController: interfaceController)
        let queue     = CarPlayQueueController()

        discoverController  = discover
        libraryController   = library
        playlistsController = playlists
        recapController     = recap
        queueController     = queue

        // Warteschlange ist kein Tab — sie wird über den Up-Next-Button im NowPlaying-Template geöffnet
        lastRecapTabVisible = recapTabVisible
        let tabs = CPTabBarTemplate(templates: visibleTabTemplates())
        tabBar = tabs
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)

        discover.load()
        library.load()
        playlists.load()
        recap.load()
        queue.load()

        setupNowPlayingTemplate()
        observeRecapVisibility()
        prefetchHeavyData()
    }

    /// Lädt im Hintergrund Daten, die der User wahrscheinlich gleich braucht (Library →
    /// Artists). Spart die ~2 s Wait-on-API beim ersten Tap auf den Artists-Eintrag.
    private func prefetchHeavyData() {
        guard !OfflineModeService.shared.isOffline else { return }
        Task.detached(priority: .utility) {
            if await LibraryStore.shared.artists.isEmpty {
                await LibraryStore.shared.loadArtists()
            }
        }
    }

    func disconnect() {
        CPNowPlayingTemplate.shared.remove(self)
        cancellables.removeAll()
        discoverController?.cancel()
        libraryController?.cancel()
        playlistsController?.cancel()
        recapController?.cancel()
        queueController?.cancel()
        discoverController  = nil
        libraryController   = nil
        playlistsController = nil
        recapController     = nil
        queueController     = nil
        tabBar              = nil
    }

    // MARK: - Tab Visibility

    private func visibleTabTemplates() -> [CPTemplate] {
        var templates: [CPTemplate] = []
        if let t = discoverController?.rootTemplate  { templates.append(t) }
        if let t = libraryController?.rootTemplate   { templates.append(t) }
        if let t = playlistsController?.rootTemplate { templates.append(t) }
        if recapTabVisible, let t = recapController?.rootTemplate {
            templates.append(t)
        }
        return templates
    }

    private var recapTabVisible: Bool {
        guard UserDefaults.standard.bool(forKey: "recapEnabled") else { return false }
        let entries = RecapStore.shared.entries
        guard !entries.isEmpty else { return false }
        if OfflineModeService.shared.isOffline {
            let downloaded = DownloadStore.shared.offlinePlaylistIds
            return entries.contains { downloaded.contains($0.playlistId) }
        }
        return true
    }

    private func observeRecapVisibility() {
        RecapStore.shared.$entries
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.refreshTabs() }
            .store(in: &cancellables)

        OfflineModeService.shared.$isOffline
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.refreshTabs() }
            .store(in: &cancellables)

        DownloadStore.shared.$offlinePlaylistIds
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard OfflineModeService.shared.isOffline else { return }
                self?.refreshTabs()
            }
            .store(in: &cancellables)

        // recapEnabled wird via UserDefaults persistiert. Notification feuert bei jeder
        // Mutation (Player-State-Saves) — nur bei tatsächlicher Toggle-Änderung reagieren.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let current = UserDefaults.standard.bool(forKey: "recapEnabled")
                guard current != self.lastRecapEnabled else { return }
                self.lastRecapEnabled = current
                self.refreshTabs()
            }
            .store(in: &cancellables)
    }

    private func refreshTabs() {
        // Nur tatsächlichen Tab-Wechsel rendern — sonst unnötige IPC-Roundtrips zu CarPlay.
        let visible = recapTabVisible
        guard visible != lastRecapTabVisible else { return }
        lastRecapTabVisible = visible
        tabBar?.updateTemplates(visibleTabTemplates())
    }

    // MARK: - Now Playing Template

    private func setupNowPlayingTemplate() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = tr("Queue", "Warteschlange")
        nowPlaying.add(self)
        updateNowPlayingButtons()

        AudioPlayerService.shared.$currentSong
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateNowPlayingButtons() }
            .store(in: &cancellables)
        LibraryStore.shared.$starredSongs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateNowPlayingButtons() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateNowPlayingButtons() }
            .store(in: &cancellables)
    }

    private func updateNowPlayingButtons() {
        var buttons: [CPNowPlayingButton] = [
            CPNowPlayingShuffleButton { _ in AudioPlayerService.shared.toggleShuffle() },
            CPNowPlayingRepeatButton  { _ in AudioPlayerService.shared.repeatMode = AudioPlayerService.shared.repeatMode.toggled },
        ]
        if #available(iOS 16.0, *),
           UserDefaults.standard.bool(forKey: "enableFavorites"),
           let song = AudioPlayerService.shared.currentSong {
            let starred = LibraryStore.shared.isSongStarred(song)
            let icon = cpIcon(starred ? "heart.fill" : "heart")
            buttons.append(CPNowPlayingImageButton(image: icon) { _ in
                Task { await LibraryStore.shared.toggleStarSong(song) }
            })
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }
}

// MARK: - CPNowPlayingTemplateObserver

extension CarPlayRootController: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            guard let template = self.queueController?.rootTemplate else { return }
            self.interfaceController.pushTemplate(template, animated: true, completion: nil)
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}
