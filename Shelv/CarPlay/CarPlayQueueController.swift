import CarPlay
import Combine

@MainActor
final class CarPlayQueueController {
    let rootTemplate: CPListTemplate
    private var cancellables = Set<AnyCancellable>()
    private var coverTask: Task<Void, Never>?

    init() {
        let t = CPListTemplate(title: tr("Queue", "Warteschlange"), sections: [])
        t.tabImage = UIImage(systemName: "list.number")
        rootTemplate = t
    }

    func load() {
        let player = AudioPlayerService.shared
        player.$currentSong  .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        player.$queue        .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        player.$currentIndex .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        player.$playNextQueue.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        player.$userQueue    .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        player.$isShuffled   .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        rebuild()
    }

    func cancel() {
        coverTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Build (1:1 zu iPhone QueueView)

    private func rebuild() {
        coverTask?.cancel()
        rootTemplate.updateSections(buildSections(imageMap: [:]))
        let songs = allQueueSongs()
        guard !songs.isEmpty else { return }
        coverTask = Task { [weak self] in
            var accumulated: [String: UIImage] = [:]
            await loadCoversIncremental(coverArtIds: songs.map { $0.coverArt }) { [weak self] chunk in
                accumulated.merge(chunk) { _, new in new }
                guard let self else { return }
                self.rootTemplate.updateSections(self.buildSections(imageMap: accumulated))
            }
        }
    }

    private func buildSections(imageMap: [String: UIImage]) -> [CPListSection] {
        let player = AudioPlayerService.shared
        var sections: [CPListSection] = []

        if player.isShuffled {
            // iPhone: nur "Shuffled Queue" wenn Shuffle aktiv.
            let albumQueue = albumQueueSongs()
            if !albumQueue.isEmpty {
                let items = albumQueue.enumerated().map { idx, song -> CPListItem in
                    let item = songListItem(song, index: idx, showCover: true) { _, c in
                        AudioPlayerService.shared.jumpToQueueTrack(at: AudioPlayerService.shared.currentIndex + 1 + idx)
                        c()
                    }
                    applyCover(to: item, coverArtId: song.coverArt, map: imageMap)
                    return item
                }
                sections.append(CPListSection(items: items, header: tr("Shuffled Queue", "Gemischte Warteschlange"), sectionIndexTitle: nil))
            }
        } else {
            // iPhone: drei Sektionen in Wiedergabe-Reihenfolge — Play Next → Up Next → Your Queue.
            if !player.playNextQueue.isEmpty {
                let songs = player.playNextQueue
                let items = songs.enumerated().map { idx, song -> CPListItem in
                    let item = songListItem(song, index: idx, showCover: true) { _, c in
                        AudioPlayerService.shared.jumpToPlayNext(at: idx); c()
                    }
                    applyCover(to: item, coverArtId: song.coverArt, map: imageMap)
                    return item
                }
                sections.append(CPListSection(items: items, header: tr("Play Next", "Als nächstes"), sectionIndexTitle: nil))
            }

            let albumQueue = albumQueueSongs()
            if !albumQueue.isEmpty {
                let items = albumQueue.enumerated().map { idx, song -> CPListItem in
                    let item = songListItem(song, index: idx, showCover: true) { _, c in
                        AudioPlayerService.shared.jumpToQueueTrack(at: AudioPlayerService.shared.currentIndex + 1 + idx)
                        c()
                    }
                    applyCover(to: item, coverArtId: song.coverArt, map: imageMap)
                    return item
                }
                sections.append(CPListSection(items: items, header: tr("Up Next", "Nächste Titel"), sectionIndexTitle: nil))
            }

            if !player.userQueue.isEmpty {
                let songs = player.userQueue
                let items = songs.enumerated().map { idx, song -> CPListItem in
                    let item = songListItem(song, index: idx, showCover: true) { _, c in
                        AudioPlayerService.shared.jumpToUserQueue(at: idx); c()
                    }
                    applyCover(to: item, coverArtId: song.coverArt, map: imageMap)
                    return item
                }
                sections.append(CPListSection(items: items, header: tr("Your Queue", "Deine Warteschlange"), sectionIndexTitle: nil))
            }
        }

        // iPhone: "Queue is empty" wenn totalCount == 0.
        if sections.isEmpty {
            let empty = CPListItem(text: tr("Queue is empty", "Warteschlange ist leer"), detailText: nil)
            sections.append(CPListSection(items: [empty], header: nil, sectionIndexTitle: nil))
        }
        return sections
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

    private func applyCover(to item: CPListItem, coverArtId: String?, map: [String: UIImage]) {
        if let id = coverArtId, let img = map[id] { item.setImage(img) }
    }
}
