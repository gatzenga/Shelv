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

    @discardableResult
    mutating func removeFromPlayNextQueue(at index: Int) -> Song? {
        guard playNextQueue.indices.contains(index) else { return nil }
        let song = playNextQueue.remove(at: index)
        if let truthIndex = truthPlayNextQueue.firstIndex(where: { $0.id == song.id }) {
            truthPlayNextQueue.remove(at: truthIndex)
        }
        return song
    }

    @discardableResult
    mutating func removeFromUserQueue(at index: Int) -> Song? {
        guard userQueue.indices.contains(index) else { return nil }
        let song = userQueue.remove(at: index)
        if let truthIndex = truthUserQueue.firstIndex(where: { $0.id == song.id }) {
            truthUserQueue.remove(at: truthIndex)
        }
        return song
    }

    mutating func clearUserQueue() {
        userQueue = []
        truthUserQueue = []
    }

    @discardableResult
    mutating func removeFromPlayQueue(at index: Int) -> Song? {
        guard queue.indices.contains(index), index != currentIndex else { return nil }
        let song = queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        if let truthIndex = truthAlbumQueue.firstIndex(where: { $0.id == song.id }) {
            truthAlbumQueue.remove(at: truthIndex)
        } else if let truthIndex = truthUserQueue.firstIndex(where: { $0.id == song.id }) {
            truthUserQueue.remove(at: truthIndex)
        }
        return song
    }

    mutating func clearUpcomingPlayQueue() {
        playNextQueue = []
        let start = currentIndex + 1
        if start < queue.count {
            queue.removeSubrange(start...)
        }
        truthPlayNextQueue = []
        truthUserQueue = []
        if let currentId = currentSong?.id {
            truthAlbumQueue = truthAlbumQueue.filter { $0.id == currentId }
        } else {
            truthAlbumQueue = []
        }
    }

    mutating func playFromQueue(index: Int) -> Song? {
        guard queue.indices.contains(index) else { return nil }
        currentIndex = index
        return queue[index]
    }

    mutating func jumpToPlayNext(at index: Int) -> Song? {
        removeFromPlayNextQueue(at: index)
    }

    mutating func jumpToQueueTrack(at queueIndex: Int) -> Song? {
        guard queue.indices.contains(queueIndex), queueIndex > currentIndex else { return nil }
        return queue.remove(at: queueIndex)
    }

    mutating func jumpToUserQueue(at index: Int) -> Song? {
        guard userQueue.indices.contains(index) else { return nil }
        return userQueue.remove(at: index)
    }

    mutating func addPlayNext(_ songs: [Song]) {
        truthPlayNextQueue.append(contentsOf: songs)
        playNextQueue.append(contentsOf: songs)
    }

    mutating func previous() -> Song? {
        let previousIndex = currentIndex - 1
        guard queue.indices.contains(previousIndex) else { return nil }
        currentIndex = previousIndex
        return queue[previousIndex]
    }

    func peekNextSong() -> Song? {
        if !playNextQueue.isEmpty { return playNextQueue[0] }
        let nextIndex = currentIndex + 1
        if nextIndex < queue.count { return queue[nextIndex] }
        if !userQueue.isEmpty { return userQueue[0] }
        return nil
    }

    mutating func advancePreparedQueueState(repeatMode: RepeatMode) {
        if !playNextQueue.isEmpty {
            playNextQueue.removeFirst()
        } else {
            let nextIndex = currentIndex + 1
            if nextIndex < queue.count {
                currentIndex = nextIndex
            } else if !userQueue.isEmpty {
                let song = userQueue.removeFirst()
                queue.append(song)
                currentIndex = queue.count - 1
            } else if repeatMode == .all && !queue.isEmpty {
                currentIndex = 0
            }
        }
    }
}
