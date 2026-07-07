import CarPlay
import Combine

@MainActor
final class CarPlayQueueController {
    let rootTemplate: CPListTemplate
    private weak var interfaceController: CPInterfaceController?
    private var cancellables = Set<AnyCancellable>()
    private var coverTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var lastSongIds: [String] = []
    private var needsRebuild = true
    // CarPlay-Listen sollten bei großen Smart-Mix-Queues nicht hunderte Rows neu bauen.
    private let queueSongPageSize = 120
    private var visibleQueueSongLimit = 120
    private var maxVisibleQueueSongLimit: Int {
        max(1, CPListTemplate.maximumItemCount - 4)
    }

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let t = CPListTemplate(title: String(localized: "queue"), sections: [])
        t.tabImage = UIImage(systemName: "list.number")
        rootTemplate = t
    }

    func load() {
        let player = AudioPlayerService.shared
        player.$currentSong  .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)
        player.$queue        .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)
        player.$currentIndex .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)
        player.$playNextQueue.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)
        player.$userQueue    .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)
        player.$isShuffled   .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &cancellables)
        needsRebuild = true
    }

    func cancel() {
        coverTask?.cancel()
        rebuildTask?.cancel()
        cancellables.removeAll()
    }

    func refreshForPresentation() {
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuild(force: true)
    }

    // MARK: - Rebuild with Debounce (FIX 9)

    private func scheduleRebuild() {
        // Queue ist kein Tab. Wenn sie nicht offen ist, kostet ein Rebuild nur
        // CarPlay-IPC/Main-Actor-Zeit und blockiert bei großen Smart-Mix-Queues.
        guard isPresented else {
            needsRebuild = true
            visibleQueueSongLimit = queueSongPageSize
            coverTask?.cancel()
            coverTask = nil
            return
        }
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    private func rebuild(force: Bool = false) {
        let songs = allQueueSongs()
        let songIds = songs.map { $0.id }

        // Identische Song-Liste → kein Replace nötig. Items sind stabil mit Cover bereits gesetzt.
        if !force, !needsRebuild, songIds == lastSongIds { return }
        needsRebuild = false
        lastSongIds = songIds

        coverTask?.cancel()
        let built = buildSections()
        prefillCoversFromCache(built.itemsByCoverId)
        rootTemplate.updateSections(built.sections)
        guard !built.itemsByCoverId.isEmpty else { return }
        coverTask = Task {
            await streamCovers(into: built.itemsByCoverId)
        }
    }

    // MARK: - Build

    private func buildSections() -> (sections: [CPListSection], itemsByCoverId: [String: [CPListItem]]) {
        let player = AudioPlayerService.shared
        var sections: [CPListSection] = []
        var itemsByCoverId: [String: [CPListItem]] = [:]
        var remainingVisibleSongs = min(visibleQueueSongLimit, maxVisibleQueueSongLimit)
        var hiddenSongCount = 0

        func register(_ item: CPListItem, coverArt: String?) {
            guard let id = coverArt else { return }
            itemsByCoverId[id, default: []].append(item)
        }

        func visibleSlice(from songs: [Song]) -> ArraySlice<Song> {
            let visibleCount = min(remainingVisibleSongs, songs.count)
            remainingVisibleSongs -= visibleCount
            hiddenSongCount += songs.count - visibleCount
            return songs.prefix(visibleCount)
        }

        func overflowItem(hiddenCount: Int) -> CPListItem? {
            guard hiddenCount > 0 else { return nil }
            let canShowMore = visibleQueueSongLimit < maxVisibleQueueSongLimit
            let item = CPListItem(
                text: canShowMore ? String(localized: "show_more") : "+\(hiddenCount) \(String(localized: "songs"))",
                detailText: canShowMore ? "+\(hiddenCount) \(String(localized: "songs"))" : nil
            )
            if canShowMore {
                item.handler = { [weak self] _, completion in
                    completion()
                    guard let self else { return }
                    self.visibleQueueSongLimit = min(
                        self.visibleQueueSongLimit + self.queueSongPageSize,
                        self.maxVisibleQueueSongLimit
                    )
                    self.rebuild(force: true)
                }
            }
            return item
        }

        func appendPlayNextSection(_ songs: [Song]) {
            guard !songs.isEmpty else { return }
            let visibleSongs = visibleSlice(from: songs)
            guard !visibleSongs.isEmpty else { return }
            let items = visibleSongs.enumerated().map { idx, song -> CPListItem in
                let item = songListItem(song, index: idx, showCover: true) { _, c in
                    c(); AudioPlayerService.shared.jumpToPlayNext(at: idx)
                }
                register(item, coverArt: song.coverArt)
                return item
            }
            sections.append(CPListSection(items: items, header: "\(String(localized: "play_next")) (\(songs.count))", sectionIndexTitle: nil))
        }

        func appendAlbumQueueSection(_ songs: [Song], title: String) {
            guard !songs.isEmpty else { return }
            let visibleSongs = visibleSlice(from: songs)
            guard !visibleSongs.isEmpty else { return }
            let items = visibleSongs.enumerated().map { idx, song -> CPListItem in
                let songId = song.id
                let item = songListItem(song, index: idx, showCover: true) { _, c in
                    c()
                    let svc = AudioPlayerService.shared
                    if let liveIdx = svc.queue.firstIndex(where: { $0.id == songId }),
                       liveIdx > svc.currentIndex {
                        svc.jumpToQueueTrack(at: liveIdx)
                    }
                }
                register(item, coverArt: song.coverArt)
                return item
            }
            sections.append(CPListSection(items: items, header: "\(title) (\(songs.count))", sectionIndexTitle: nil))
        }

        func appendUserQueueSection(_ songs: [Song]) {
            guard !songs.isEmpty else { return }
            let visibleSongs = visibleSlice(from: songs)
            guard !visibleSongs.isEmpty else { return }
            let items = visibleSongs.enumerated().map { idx, song -> CPListItem in
                let item = songListItem(song, index: idx, showCover: true) { _, c in
                    c(); AudioPlayerService.shared.jumpToUserQueue(at: idx)
                }
                register(item, coverArt: song.coverArt)
                return item
            }
            sections.append(CPListSection(items: items, header: "\(String(localized: "your_queue")) (\(songs.count))", sectionIndexTitle: nil))
        }

        if player.isShuffled {
            appendPlayNextSection(player.playNextQueue)
            appendAlbumQueueSection(albumQueueSongs(), title: String(localized: "shuffled_queue"))
        } else {
            appendPlayNextSection(player.playNextQueue)
            appendAlbumQueueSection(albumQueueSongs(), title: String(localized: "up_next"))

            appendUserQueueSection(player.userQueue)
        }

        let hasSongs = !sections.isEmpty || hiddenSongCount > 0
        if let item = overflowItem(hiddenCount: hiddenSongCount) {
            sections.append(CPListSection(items: [item], header: nil, sectionIndexTitle: nil))
        }

        // Infinity-Zeile immer ganz oben (auch bei leerer Queue).
        sections.insert(makeInfinitySection(), at: 0)
        if !hasSongs {
            let empty = CPListItem(text: String(localized: "queue_is_empty"), detailText: nil)
            sections.append(CPListSection(items: [empty], header: nil, sectionIndexTitle: nil))
        }
        return (sections, itemsByCoverId)
    }

    private var isPresented: Bool {
        guard let interfaceController else { return false }
        return interfaceController.topTemplate === rootTemplate
            || interfaceController.templates.contains { $0 === rootTemplate }
    }

    /// „Infinity Mode · An/Aus" als oberste Zeile — Tippen schaltet um (wie iPhone-Queue).
    private func makeInfinitySection() -> CPListSection {
        let on = UserDefaults.standard.bool(forKey: "infinityModeEnabled")
        let item = CPListItem(
            text: String(localized: "infinity_mode"),
            detailText: on ? String(localized: "on") : String(localized: "off"),
            image: cpIcon("infinity", pointSize: 22),
            accessoryImage: nil,
            accessoryType: .none
        )
        item.handler = { [weak self] _, completion in
            completion()
            let newOn = !UserDefaults.standard.bool(forKey: "infinityModeEnabled")
            UserDefaults.standard.set(newOn, forKey: "infinityModeEnabled")
            if newOn { AudioPlayerService.shared.topUpInfinityIfNeeded(startIfIdle: true) }
            // Liste neu aufbauen → frische Zeile (Tipp-Highlight verschwindet, Zustand aktualisiert),
            // genau wie die Album-Action-Buttons (Favorit/Play Next). Gate aushebeln, da sich die
            // Songliste beim Ausschalten nicht ändert.
            self?.lastSongIds = []
            self?.scheduleRebuild()
        }
        return CPListSection(items: [item])
    }

    // MARK: - Helpers

    private func allQueueSongs() -> [Song] {
        let player = AudioPlayerService.shared
        var songs: [Song] = []
        songs.append(contentsOf: albumQueueSongs())
        songs.append(contentsOf: player.playNextQueue)
        songs.append(contentsOf: player.userQueue)
        return songs
    }

    private func albumQueueSongs() -> [Song] {
        let player = AudioPlayerService.shared
        let start = player.currentIndex + 1
        guard start < player.queue.count else { return [] }
        return Array(player.queue[start...])
    }
}
