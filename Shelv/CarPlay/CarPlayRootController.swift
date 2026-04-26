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
    private var lastEnablePlaylists: Bool = UserDefaults.standard.bool(forKey: "enablePlaylists")
    private var lastRecapTabVisible: Bool = false

    // Apple's System-Buttons. EINMAL gebaut und stabil geteilt — Apple liest deren Selected-State
    // autonom aus MPRemoteCommandCenter, der State wird in `applyPlaybackModeToNowPlayingInfo`
    // (didSet auf isShuffled/repeatMode) gespiegelt. Würden wir die Instanzen bei jedem
    // currentSong-Wechsel neu bauen, flackerten Shuffle/Repeat-Buttons kurz beim Track-Wechsel.
    private let cachedShuffleButton = CPNowPlayingShuffleButton { _ in
        AudioPlayerService.shared.toggleShuffle()
    }
    private let cachedRepeatButton = CPNowPlayingRepeatButton { _ in
        AudioPlayerService.shared.cycleRepeatMode()
    }

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

        // CarPlay-only-Start: ShelvApp's .task läuft auf dem UIWindowScene-Lifecycle.
        // Bei reinem CarPlay-Start (iPhone-Screen bleibt dunkel) kann DownloadStore
        // noch kein serverId haben, weil setActiveServer noch nicht aufgerufen wurde.
        // Hier explizit bootstrappen — alle Operationen sind idempotent.
        Task { @MainActor in
            await DownloadDatabase.shared.setup()
            await DownloadService.shared.setup()
            await PlayLogService.shared.setup()
            let tempStore = ServerStore()
            if let server = tempStore.activeServer, !server.stableId.isEmpty {
                await DownloadStore.shared.setActiveServer(server.stableId)
                // Offline-Modus: Playlists und Recap aus Disk-Cache / SQLite laden,
                // da ShelvApp's .task bei reinem CarPlay-Start ggf. nicht läuft.
                if OfflineModeService.shared.isOffline {
                    await LibraryStore.shared.loadPlaylists()
                }
                await RecapStore.shared.loadEntries(serverId: server.stableId)
            }
        }

        discover.load()
        library.load()
        playlists.load()
        recap.load()
        queue.load()

        AudioPlayerService.shared.isCarPlayActive = true

        // FIX 4: Korrupten Player-State nach Crash sauber zurücksetzen
        let player = AudioPlayerService.shared
        if player.currentSong == nil && player.currentIndex > 0 {
            player.stop()
        }

        setupNowPlayingTemplate()
        observeRecapVisibility()
        prefetchHeavyData()
    }

    /// Lädt im Hintergrund Daten, die der User wahrscheinlich gleich braucht (Library →
    /// Artists). Spart die ~2 s Wait-on-API beim ersten Tap auf den Artists-Eintrag.
    /// Im Offline-Modus: Artists aus Disk-Cache laden damit artistSource() korrekte
    /// coverArt-IDs aus dem LibraryStore nutzt statt ggf. nil aus DownloadedArtist.
    private func prefetchHeavyData() {
        Task.detached(priority: .utility) {
            if await LibraryStore.shared.artists.isEmpty {
                await LibraryStore.shared.loadArtists()
            }
        }
    }

    func disconnect() {
        AudioPlayerService.shared.isCarPlayActive = false
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
        if UserDefaults.standard.bool(forKey: "enablePlaylists"),
           let t = playlistsController?.rootTemplate {
            templates.append(t)
        }
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

        // recapEnabled und enablePlaylists via UserDefaults — nur bei Änderung reagieren.
        // lastRecapEnabled/lastEnablePlaylists werden ausschliesslich in refreshTabs() upgedated,
        // damit der Vergleich dort funktioniert (sonst sind sie schon gleich, bevor refreshTabs läuft).
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let currentRecap = UserDefaults.standard.bool(forKey: "recapEnabled")
                let currentPlaylists = UserDefaults.standard.bool(forKey: "enablePlaylists")
                guard currentRecap != self.lastRecapEnabled || currentPlaylists != self.lastEnablePlaylists else { return }
                self.refreshTabs()
            }
            .store(in: &cancellables)
    }

    private func refreshTabs() {
        // Nur tatsächlichen Tab-Wechsel rendern — sonst unnötige IPC-Roundtrips zu CarPlay.
        let recapVisible = recapTabVisible
        let recapEnabled = UserDefaults.standard.bool(forKey: "recapEnabled")
        let playlistsEnabled = UserDefaults.standard.bool(forKey: "enablePlaylists")
        guard recapVisible != lastRecapTabVisible
              || recapEnabled != lastRecapEnabled
              || playlistsEnabled != lastEnablePlaylists else { return }
        lastRecapTabVisible = recapVisible
        lastRecapEnabled = recapEnabled
        lastEnablePlaylists = playlistsEnabled
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
        // $starredSongs feuert SOFORT beim optimistischen Toggle in toggleStarSong.
        LibraryStore.shared.$starredSongs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateNowPlayingButtons() }
            .store(in: &cancellables)
        // Bewusst KEINE Sinks auf $isShuffled / $repeatMode: Apple's System-Buttons
        // (CPNowPlayingShuffle-/RepeatButton) lesen ihren Selected-State autonom vom
        // MPRemoteCommandCenter. Würden wir bei jedem State-Wechsel die Buttons neu
        // bauen, flackerte der Frame zwischen Tap-Highlight und Re-Erstellung.
        // enableFavorites-Toggle. Filter auf den Key, sonst rauscht jeder Player-State-Save durch.
        var lastEnableFav  = UserDefaults.standard.bool(forKey: "enableFavorites")
        var lastThemeColor = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let currentFav   = UserDefaults.standard.bool(forKey: "enableFavorites")
                let currentTheme = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                if currentFav != lastEnableFav {
                    lastEnableFav = currentFav
                    self?.updateNowPlayingButtons()
                }
                if currentTheme != lastThemeColor {
                    lastThemeColor = currentTheme
                    self?.updateNowPlayingButtons()
                }
            }
            .store(in: &cancellables)
    }

    private func updateNowPlayingButtons() {
        let song = AudioPlayerService.shared.currentSong
        let starred = song.map { LibraryStore.shared.isSongStarred($0) } ?? false

        // Geteilte System-Buttons (immer dieselben Instanzen) + frisch gebauter Heart-Button
        // (CPNowPlayingImageButton.image ist init-only, lässt sich nicht mutieren — daher
        // bei Track-/Starred-Wechsel neu bauen). Shuffle/Repeat bleiben stabil.
        var buttons: [CPNowPlayingButton] = [cachedShuffleButton, cachedRepeatButton]
        if #available(iOS 16.0, *),
           UserDefaults.standard.bool(forKey: "enableFavorites"),
           let song {
            let icon = UIImage(systemName: starred ? "heart.fill" : "heart") ?? UIImage()
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
            guard let queue = self.queueController?.rootTemplate else { return }
            let ic = self.interfaceController

            // Queue ist schon top: nichts tun.
            if ic.topTemplate === queue { return }

            // Queue ist irgendwo im Stack: dorthin springen statt erneut pushen.
            if ic.templates.contains(where: { $0 === queue }) {
                ic.pop(to: queue, animated: true, completion: nil)
                return
            }

            // Apple's CarPlay-Hierarchy-Limit ist 5, aber das automatisch eingeblendete
            // CPNowPlayingTemplate belegt einen virtuellen Slot. Aus dem Player heraus
            // immer auf den Tab-Root zurückspringen, dann frisch pushen — vermeidet
            // den NSGenericException 'Application exceeded the hierarchy depth limit'-Crash
            // wenn der User vorher tief navigiert war (Library > Albums > AlbumDetail).
            if ic.templates.count >= 3 {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    ic.popToRootTemplate(animated: false) { _, _ in cont.resume() }
                }
            }
            ic.pushTemplate(queue, animated: true, completion: nil)
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}
