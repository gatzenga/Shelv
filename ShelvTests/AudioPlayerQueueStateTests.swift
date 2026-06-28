import XCTest
@testable import Shelv

final class AudioPlayerQueueStateTests: XCTestCase {
    func testPlayNextWinsOverAlbumQueueAndRemovesTruthEntry() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 0,
            playNextQueue: [testSong("next-1"), testSong("next-2")],
            truthPlayNextQueue: [testSong("next-1"), testSong("next-2")],
            currentSong: testSong("album-1")
        )

        let action = state.advance(repeatMode: .off, isShuffled: false, triggeredByUser: false)

        XCTAssertEqual(action.playedSongId, "next-1")
        XCTAssertEqual(state.queue.map(\.id), ["album-1", "album-2"])
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(state.playNextQueue.map(\.id), ["next-2"])
        XCTAssertEqual(state.truthPlayNextQueue.map(\.id), ["next-2"])
    }

    func testAutoRepeatOneReplaysCurrentSongWithoutConsumingQueues() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 0,
            currentSong: testSong("album-1")
        )

        let action = state.advance(repeatMode: .one, isShuffled: false, triggeredByUser: false)

        XCTAssertEqual(action.playedSongId, "album-1")
        XCTAssertEqual(state.queue.map(\.id), ["album-1", "album-2"])
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testPlayNextStillWinsOverAutoRepeatOne() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 0,
            playNextQueue: [testSong("next-1")],
            truthPlayNextQueue: [testSong("next-1")],
            currentSong: testSong("album-1")
        )

        let action = state.advance(repeatMode: .one, isShuffled: false, triggeredByUser: false)

        XCTAssertEqual(action.playedSongId, "next-1")
        XCTAssertTrue(state.playNextQueue.isEmpty)
        XCTAssertTrue(state.truthPlayNextQueue.isEmpty)
    }

    func testUserTriggeredNextIgnoresRepeatOneAndAdvancesAlbumQueue() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 0,
            currentSong: testSong("album-1")
        )

        let action = state.advance(repeatMode: .one, isShuffled: false, triggeredByUser: true)

        XCTAssertEqual(action.playedSongId, "album-2")
        XCTAssertEqual(state.currentIndex, 1)
    }

    func testUserQueueIsAppendedWhenAlbumQueueEnds() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            userQueue: [testSong("user-1"), testSong("user-2")],
            truthUserQueue: [testSong("user-1"), testSong("user-2")],
            currentSong: testSong("album-1")
        )

        let action = state.advance(repeatMode: .off, isShuffled: false, triggeredByUser: false)

        XCTAssertEqual(action.playedSongId, "user-1")
        XCTAssertEqual(state.queue.map(\.id), ["album-1", "user-1"])
        XCTAssertEqual(state.currentIndex, 1)
        XCTAssertEqual(state.userQueue.map(\.id), ["user-2"])
        XCTAssertEqual(state.truthUserQueue.map(\.id), ["user-1", "user-2"])
    }

    func testRepeatAllRebuildsQueueFromTruthQueuesAtEnd() {
        var state = makeQueueState(
            queue: [testSong("album-2")],
            currentIndex: 0,
            truthAlbumQueue: [testSong("album-1"), testSong("album-2")],
            truthPlayNextQueue: [testSong("old-next")],
            truthUserQueue: [testSong("user-1")],
            currentSong: testSong("album-2")
        )

        let action = state.advance(repeatMode: .all, isShuffled: false, triggeredByUser: false)

        XCTAssertEqual(action.playedSongId, "album-1")
        XCTAssertEqual(state.queue.map(\.id), ["album-1", "album-2", "user-1"])
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertTrue(state.playNextQueue.isEmpty)
        XCTAssertTrue(state.userQueue.isEmpty)
        XCTAssertEqual(state.truthAlbumQueue.map(\.id), ["album-1", "album-2", "user-1"])
        XCTAssertTrue(state.truthPlayNextQueue.isEmpty)
        XCTAssertTrue(state.truthUserQueue.isEmpty)
    }

    func testRepeatAllUsesShuffleWhenEnabled() {
        var state = makeQueueState(
            queue: [testSong("album-3")],
            currentIndex: 0,
            truthAlbumQueue: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            currentSong: testSong("album-3")
        )

        let action = state.advance(
            repeatMode: .all,
            isShuffled: true,
            triggeredByUser: false,
            shuffle: { Array($0.reversed()) }
        )

        XCTAssertEqual(action.playedSongId, "album-3")
        XCTAssertEqual(state.queue.map(\.id), ["album-3", "album-2", "album-1"])
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testClearsPlaybackWhenNoUpcomingSongAndRepeatIsOff() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            currentSong: testSong("album-1")
        )

        let action = state.advance(repeatMode: .off, isShuffled: false, triggeredByUser: false)

        XCTAssertEqual(action, .clearPlayback)
        XCTAssertEqual(state.queue.map(\.id), ["album-1"])
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testRemoveFromPlayNextQueueRemovesVisibleAndTruthEntry() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            playNextQueue: [testSong("next-1"), testSong("next-2")],
            truthPlayNextQueue: [testSong("next-1"), testSong("next-2")]
        )

        let removed = state.removeFromPlayNextQueue(at: 0)

        XCTAssertEqual(removed?.id, "next-1")
        XCTAssertEqual(state.playNextQueue.map(\.id), ["next-2"])
        XCTAssertEqual(state.truthPlayNextQueue.map(\.id), ["next-2"])
    }

    func testRemoveFromUserQueueRemovesVisibleAndTruthEntry() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            userQueue: [testSong("user-1"), testSong("user-2")],
            truthUserQueue: [testSong("user-1"), testSong("user-2")]
        )

        let removed = state.removeFromUserQueue(at: 1)

        XCTAssertEqual(removed?.id, "user-2")
        XCTAssertEqual(state.userQueue.map(\.id), ["user-1"])
        XCTAssertEqual(state.truthUserQueue.map(\.id), ["user-1"])
    }

    func testRemoveFromPlayQueueBeforeCurrentShiftsCurrentIndexAndTruth() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            currentIndex: 1,
            truthAlbumQueue: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            currentSong: testSong("album-2")
        )

        let removed = state.removeFromPlayQueue(at: 0)

        XCTAssertEqual(removed?.id, "album-1")
        XCTAssertEqual(state.queue.map(\.id), ["album-2", "album-3"])
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(state.truthAlbumQueue.map(\.id), ["album-2", "album-3"])
    }

    func testRemoveFromPlayQueueIgnoresCurrentSong() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 0,
            currentSong: testSong("album-1")
        )

        let removed = state.removeFromPlayQueue(at: 0)

        XCTAssertNil(removed)
        XCTAssertEqual(state.queue.map(\.id), ["album-1", "album-2"])
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testClearUserQueueRemovesVisibleAndTruthUserQueue() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            userQueue: [testSong("user-1")],
            truthUserQueue: [testSong("user-1")]
        )

        state.clearUserQueue()

        XCTAssertTrue(state.userQueue.isEmpty)
        XCTAssertTrue(state.truthUserQueue.isEmpty)
    }

    func testClearUpcomingPlayQueueKeepsCurrentSongTruthAndVisibleUserQueue() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            currentIndex: 1,
            playNextQueue: [testSong("next-1")],
            userQueue: [testSong("user-1")],
            truthAlbumQueue: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            truthPlayNextQueue: [testSong("next-1")],
            truthUserQueue: [testSong("user-1")],
            currentSong: testSong("album-2")
        )

        state.clearUpcomingPlayQueue()

        XCTAssertEqual(state.queue.map(\.id), ["album-1", "album-2"])
        XCTAssertEqual(state.currentIndex, 1)
        XCTAssertTrue(state.playNextQueue.isEmpty)
        XCTAssertEqual(state.userQueue.map(\.id), ["user-1"])
        XCTAssertEqual(state.truthAlbumQueue.map(\.id), ["album-2"])
        XCTAssertTrue(state.truthPlayNextQueue.isEmpty)
        XCTAssertTrue(state.truthUserQueue.isEmpty)
    }

    func testPlayFromQueueUpdatesCurrentIndexAndReturnsSong() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            currentIndex: 0
        )

        let song = state.playFromQueue(index: 2)

        XCTAssertEqual(song?.id, "album-3")
        XCTAssertEqual(state.currentIndex, 2)
    }

    func testJumpToPlayNextRemovesSelectedSongAndTruthEntry() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            playNextQueue: [testSong("next-1"), testSong("next-2")],
            truthPlayNextQueue: [testSong("next-1"), testSong("next-2")]
        )

        let song = state.jumpToPlayNext(at: 1)

        XCTAssertEqual(song?.id, "next-2")
        XCTAssertEqual(state.playNextQueue.map(\.id), ["next-1"])
        XCTAssertEqual(state.truthPlayNextQueue.map(\.id), ["next-1"])
    }

    func testJumpToQueueTrackOnlyAllowsUpcomingAlbumTracks() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            currentIndex: 1,
            currentSong: testSong("album-2")
        )

        XCTAssertNil(state.jumpToQueueTrack(at: 1))

        let song = state.jumpToQueueTrack(at: 2)

        XCTAssertEqual(song?.id, "album-3")
        XCTAssertEqual(state.queue.map(\.id), ["album-1", "album-2"])
        XCTAssertEqual(state.currentIndex, 1)
    }

    func testJumpToUserQueueRemovesVisibleEntryButKeepsTruthQueue() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            userQueue: [testSong("user-1"), testSong("user-2")],
            truthUserQueue: [testSong("user-1"), testSong("user-2")]
        )

        let song = state.jumpToUserQueue(at: 0)

        XCTAssertEqual(song?.id, "user-1")
        XCTAssertEqual(state.userQueue.map(\.id), ["user-2"])
        XCTAssertEqual(state.truthUserQueue.map(\.id), ["user-1", "user-2"])
    }

    func testAddPlayNextAppendsVisibleAndTruthEntries() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            playNextQueue: [testSong("next-1")],
            truthPlayNextQueue: [testSong("next-1")]
        )

        state.addPlayNext([testSong("next-2"), testSong("next-3")])

        XCTAssertEqual(state.playNextQueue.map(\.id), ["next-1", "next-2", "next-3"])
        XCTAssertEqual(state.truthPlayNextQueue.map(\.id), ["next-1", "next-2", "next-3"])
    }
}

private func testSong(_ id: String) -> Song {
    Song(id: id, title: "Song \(id)")
}

private func makeQueueState(
    queue: [Song],
    currentIndex: Int,
    playNextQueue: [Song] = [],
    userQueue: [Song] = [],
    truthAlbumQueue: [Song]? = nil,
    truthPlayNextQueue: [Song] = [],
    truthUserQueue: [Song] = [],
    currentSong: Song? = nil
) -> AudioPlayerQueueState {
    AudioPlayerQueueState(
        queue: queue,
        currentIndex: currentIndex,
        playNextQueue: playNextQueue,
        userQueue: userQueue,
        truthAlbumQueue: truthAlbumQueue ?? queue,
        truthPlayNextQueue: truthPlayNextQueue,
        truthUserQueue: truthUserQueue,
        currentSong: currentSong
    )
}

private extension AudioPlayerQueueAdvanceAction {
    var playedSongId: String? {
        guard case .play(let song) = self else { return nil }
        return song.id
    }
}
