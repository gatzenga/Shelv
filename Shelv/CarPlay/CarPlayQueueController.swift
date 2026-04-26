import CarPlay
import Combine

@MainActor
final class CarPlayQueueController {
    let rootTemplate: CPListTemplate
    private var cancellables = Set<AnyCancellable>()
    private var coverTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var lastSongIds: [String] = []

    init() {
        let t = CPListTemplate(title: tr("Queue", "Warteschlange"), sections: [])
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
        scheduleRebuild()
    }

    func cancel() {
        coverTask?.cancel()
        rebuildTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Rebuild with Debounce (FIX 9)

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            rebuild()
        }
    }

    private func rebuild() {
        let songs = allQueueSongs()
        let songIds = songs.map { $0.id }

        // Identische Song-Liste → kein Replace nötig. Items sind stabil mit Cover bereits gesetzt.
        if songIds == lastSongIds { return }
        lastSongIds = songIds

        coverTask?.cancel()
        let built = buildSections()
        rootTemplate.updateSections(built.sections)
        guard !built.itemsByCoverId.isEmpty else { return }
        coverTask = Task {
            await streamCovers(into: built.itemsByCoverId)
        }
    }

    // MARK: - Build (1:1 zu iPhone QueueView)

    private func buildSections() -> (sections: [CPListSection], itemsByCoverId: [String: [CPListItem]]) {
        let player = AudioPlayerService.shared
        var sections: [CPListSection] = []
        var itemsByCoverId: [String: [CPListItem]] = [:]

        func register(_ item: CPListItem, coverArt: String?) {
            guard let id = coverArt else { return }
            itemsByCoverId[id, default: []].append(item)
        }

        if player.isShuffled {
            let albumQueue = albumQueueSongs()
            if !albumQueue.isEmpty {
                let items = albumQueue.enumerated().map { idx, song -> CPListItem in
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
                sections.append(CPListSection(items: items, header: tr("Shuffled Queue", "Gemischte Warteschlange"), sectionIndexTitle: nil))
            }
        } else {
            if !player.playNextQueue.isEmpty {
                let songs = player.playNextQueue
                let items = songs.enumerated().map { idx, song -> CPListItem in
                    let item = songListItem(song, index: idx, showCover: true) { _, c in
                        c(); AudioPlayerService.shared.jumpToPlayNext(at: idx)
                    }
                    register(item, coverArt: song.coverArt)
                    return item
                }
                sections.append(CPListSection(items: items, header: tr("Play Next", "Als nächstes"), sectionIndexTitle: nil))
            }

            let albumQueue = albumQueueSongs()
            if !albumQueue.isEmpty {
                let items = albumQueue.enumerated().map { idx, song -> CPListItem in
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
                sections.append(CPListSection(items: items, header: tr("Up Next", "Nächste Titel"), sectionIndexTitle: nil))
            }

            if !player.userQueue.isEmpty {
                let songs = player.userQueue
                let items = songs.enumerated().map { idx, song -> CPListItem in
                    let item = songListItem(song, index: idx, showCover: true) { _, c in
                        c(); AudioPlayerService.shared.jumpToUserQueue(at: idx)
                    }
                    register(item, coverArt: song.coverArt)
                    return item
                }
                sections.append(CPListSection(items: items, header: tr("Your Queue", "Deine Warteschlange"), sectionIndexTitle: nil))
            }
        }

        if sections.isEmpty {
            let empty = CPListItem(text: tr("Queue is empty", "Warteschlange ist leer"), detailText: nil)
            sections.append(CPListSection(items: [empty], header: nil, sectionIndexTitle: nil))
        }
        return (sections, itemsByCoverId)
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
