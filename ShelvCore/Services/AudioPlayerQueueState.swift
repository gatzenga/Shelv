import Foundation

nonisolated enum AudioPlayerQueueAdvanceAction: Equatable {
    case play(Song)
    case clearPlayback
    case none
}

nonisolated struct AudioPlayerQueueState: Equatable {
    var queue: [Song]
    var currentIndex: Int
    var playNextQueue: [Song]
    var userQueue: [Song]
    var truthAlbumQueue: [Song]
    var truthPlayNextQueue: [Song]
    var truthUserQueue: [Song]
    var currentSong: Song?

    mutating func advance(
        repeatMode: RepeatMode,
        isShuffled: Bool,
        triggeredByUser: Bool,
        shuffle: ([Song]) -> [Song] = { $0.shuffled() }
    ) -> AudioPlayerQueueAdvanceAction {
        if repeatMode == .one && !triggeredByUser && playNextQueue.isEmpty {
            guard let currentSong else { return .none }
            return .play(currentSong)
        }

        if !playNextQueue.isEmpty {
            let song = playNextQueue.removeFirst()
            if let index = truthPlayNextQueue.firstIndex(where: { $0.id == song.id }) {
                truthPlayNextQueue.remove(at: index)
            }
            return .play(song)
        }

        let nextIndex = currentIndex + 1
        if nextIndex < queue.count {
            currentIndex = nextIndex
            return .play(queue[nextIndex])
        }

        if !userQueue.isEmpty {
            let song = userQueue.removeFirst()
            queue.append(song)
            currentIndex = queue.count - 1
            return .play(song)
        }

        if repeatMode == .all && !(truthAlbumQueue.isEmpty && truthUserQueue.isEmpty) {
            let fullTruth = truthAlbumQueue + truthUserQueue
            truthAlbumQueue = fullTruth
            truthUserQueue = []
            truthPlayNextQueue = []
            queue = isShuffled ? shuffle(fullTruth) : fullTruth
            playNextQueue = []
            userQueue = []
            currentIndex = 0
            return queue.isEmpty ? .clearPlayback : .play(queue[0])
        }

        return .clearPlayback
    }
}
