import XCTest

final class AudioPlayerQueueStateTests: XCTestCase {
    func testNewLogicalPlaybackStopsCurrentEngineEvenForSameSong() {
        XCTAssertTrue(
            AudioPlayerPlaybackTransitionPolicy.shouldStopEngine(
                currentSongId: "song-a",
                targetSongId: "song-a",
                startsNewTrackingSession: true
            )
        )
    }

    func testInternalReconnectOfSameSongKeepsTransitionContinuous() {
        XCTAssertFalse(
            AudioPlayerPlaybackTransitionPolicy.shouldStopEngine(
                currentSongId: "song-a",
                targetSongId: "song-a",
                startsNewTrackingSession: false
            )
        )
    }

    func testDifferentSongAlwaysStopsCurrentEngine() {
        XCTAssertTrue(
            AudioPlayerPlaybackTransitionPolicy.shouldStopEngine(
                currentSongId: "song-a",
                targetSongId: "song-b",
                startsNewTrackingSession: false
            )
        )
    }

    func testPlayerVolumeKeepsMacMasterVolumeWithoutReplayGain() {
        XCTAssertEqual(
            PlayerEngineVolumePolicy.effectiveVolume(
                masterVolume: 0.25,
                replayGainVolume: 1
            ),
            0.25,
            accuracy: 0.0001
        )
    }

    func testPlayerVolumeCombinesMasterVolumeAndReplayGain() {
        XCTAssertEqual(
            PlayerEngineVolumePolicy.effectiveVolume(
                masterVolume: 0.4,
                replayGainVolume: 0.5
            ),
            0.2,
            accuracy: 0.0001
        )
    }

    func testTenDirectSelectionsRestoreActualPlaybackOrderInReverse() {
        let linearSong = testSong("linear")
        let selectedSongs = (1...10).map { testSong("selected-\($0)") }
        var queue = [linearSong] + selectedSongs
        var currentSong = linearSong
        var history = AudioPlayerBackHistoryState()

        for selectedSong in selectedSongs {
            history.recordTransition(
                from: currentSong,
                to: selectedSong,
                queue: queue,
                currentIndex: 0
            )
            queue.removeAll { $0.id == selectedSong.id }
            currentSong = selectedSong
        }

        var previousSongIDs: [String] = []
        var resolvedAnchorIndexes: [Int?] = []
        while let selection = history.popPrevious(in: queue) {
            previousSongIDs.append(selection.song.id)
            resolvedAnchorIndexes.append(selection.queueAnchorIndex)
        }

        let expected = selectedSongs.dropLast().reversed().map(\.id) + [linearSong.id]
        XCTAssertEqual(previousSongIDs, expected)
        XCTAssertEqual(resolvedAnchorIndexes.compactMap { $0 }, Array(repeating: 0, count: 10))
    }

    func testMixedDirectSelectionsAndNormalNextRestoreChronologicalOrder() {
        let songs = ["a", "b", "c", "d", "e"].map(testSong)
        var state = makeQueueState(
            queue: songs,
            currentIndex: 0,
            currentSong: songs[0]
        )
        var history = AudioPlayerBackHistoryState()

        history.recordTransition(
            from: state.currentSong,
            to: songs[3],
            queue: state.queue,
            currentIndex: state.currentIndex
        )
        state.currentSong = state.jumpToQueueTrack(at: 3)

        let firstNextSourceSong = state.currentSong
        let firstNextSourceQueue = state.queue
        let firstNextSourceIndex = state.currentIndex
        let firstNext = state.advance(
            repeatMode: .off,
            isShuffled: false,
            triggeredByUser: true
        )
        guard case .play(let firstNextSong) = firstNext else {
            return XCTFail("Expected the first linear next song")
        }
        history.recordTransition(
            from: firstNextSourceSong,
            to: firstNextSong,
            queue: firstNextSourceQueue,
            currentIndex: firstNextSourceIndex,
            recordsSameSong: true
        )
        state.currentSong = firstNextSong

        history.recordTransition(
            from: state.currentSong,
            to: songs[4],
            queue: state.queue,
            currentIndex: state.currentIndex
        )
        state.currentSong = state.jumpToQueueTrack(at: 3)

        let secondNextSourceSong = state.currentSong
        let secondNextSourceQueue = state.queue
        let secondNextSourceIndex = state.currentIndex
        let secondNext = state.advance(
            repeatMode: .off,
            isShuffled: false,
            triggeredByUser: true
        )
        guard case .play(let secondNextSong) = secondNext else {
            return XCTFail("Expected the second linear next song")
        }
        history.recordTransition(
            from: secondNextSourceSong,
            to: secondNextSong,
            queue: secondNextSourceQueue,
            currentIndex: secondNextSourceIndex,
            recordsSameSong: true
        )
        state.currentSong = secondNextSong

        var previousSongIDs: [String] = []
        var restoredIndexes: [Int] = []
        while let selection = history.popPrevious(in: state.queue) {
            previousSongIDs.append(selection.song.id)
            if let anchorIndex = selection.queueAnchorIndex {
                state.currentIndex = anchorIndex
                restoredIndexes.append(anchorIndex)
            }
            state.currentSong = selection.song
        }

        XCTAssertEqual(previousSongIDs, ["e", "b", "d", "a"])
        XCTAssertEqual(restoredIndexes, [1, 1, 0, 0])
        XCTAssertEqual(state.queue.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(state.truthAlbumQueue.map(\.id), ["a", "b", "c", "d", "e"])
    }

    func testSameSongTransitionDoesNotCreateHistoryEntry() {
        var history = AudioPlayerBackHistoryState()

        history.recordTransition(
            from: Song(id: "same", title: "Old metadata"),
            to: Song(id: "same", title: "New metadata"),
            queue: [testSong("same")],
            currentIndex: 0
        )

        XCTAssertEqual(history.count, 0)
        XCTAssertNil(history.previousSong)
    }

    func testSameSongHistoryPolicyDistinguishesPlayNextFromAutomaticRepeatOne() {
        XCTAssertFalse(AudioPlayerBackHistoryState.recordsSameSongForNext(
            repeatMode: .one,
            triggeredByUser: false,
            hasPlayNextBeforeAdvance: false
        ))
        XCTAssertTrue(AudioPlayerBackHistoryState.recordsSameSongForNext(
            repeatMode: .one,
            triggeredByUser: false,
            hasPlayNextBeforeAdvance: true
        ))
        XCTAssertTrue(AudioPlayerBackHistoryState.recordsSameSongForNext(
            repeatMode: .one,
            triggeredByUser: true,
            hasPlayNextBeforeAdvance: false
        ))
    }

    func testDistinctQueueOccurrencesWithSameSongIDKeepTheirAnchors() {
        let firstOccurrence = Song(id: "same", title: "First occurrence")
        let secondOccurrence = Song(id: "same", title: "Second occurrence")
        let nextSong = testSong("next")
        let queue = [firstOccurrence, secondOccurrence, nextSong]
        var history = AudioPlayerBackHistoryState()

        history.recordTransition(
            from: firstOccurrence,
            to: secondOccurrence,
            queue: queue,
            currentIndex: 0,
            recordsSameSong: true
        )
        history.recordTransition(
            from: secondOccurrence,
            to: nextSong,
            queue: queue,
            currentIndex: 1,
            recordsSameSong: true
        )

        let secondSelection = history.popPrevious(in: queue)
        let firstSelection = history.popPrevious(in: queue)

        XCTAssertEqual(secondSelection?.song.title, "Second occurrence")
        XCTAssertEqual(secondSelection?.queueAnchorIndex, 1)
        XCTAssertEqual(firstSelection?.song.title, "First occurrence")
        XCTAssertEqual(firstSelection?.queueAnchorIndex, 0)
    }

    func testHistoryKeepsOnlyMostRecentFiveHundredEntries() {
        var history = AudioPlayerBackHistoryState()
        var currentSong = testSong("song-0")

        for index in 1...501 {
            let nextSong = testSong("song-\(index)")
            history.recordTransition(
                from: currentSong,
                to: nextSong,
                queue: [currentSong],
                currentIndex: 0
            )
            currentSong = nextSong
        }

        XCTAssertEqual(history.count, 500)
        XCTAssertEqual(history.popPrevious(in: [])?.song.id, "song-500")

        var oldestRemainingSongID: String?
        while let selection = history.popPrevious(in: []) {
            oldestRemainingSongID = selection.song.id
        }
        XCTAssertEqual(oldestRemainingSongID, "song-1")
    }

    func testHistoryAnchorResolvesByIDAfterQueueReorder() {
        let queue = [testSong("a"), testSong("b"), testSong("c")]
        var history = AudioPlayerBackHistoryState()
        history.recordTransition(
            from: queue[1],
            to: testSong("detached"),
            queue: queue,
            currentIndex: 1
        )

        let selection = history.popPrevious(
            in: [testSong("c"), testSong("a"), testSong("b")]
        )

        XCTAssertEqual(selection?.song.id, "b")
        XCTAssertEqual(selection?.queueAnchorIndex, 2)
    }

    func testDeletedHistoryAnchorDoesNotSelectUnrelatedQueueSong() {
        let queue = [testSong("a"), testSong("b"), testSong("c")]
        var history = AudioPlayerBackHistoryState()
        history.recordTransition(
            from: testSong("detached-history-song"),
            to: testSong("next-song"),
            queue: queue,
            currentIndex: 1
        )

        let selection = history.popPrevious(
            in: [testSong("a"), testSong("detached-history-song"), testSong("c")]
        )

        XCTAssertEqual(selection?.song.id, "detached-history-song")
        XCTAssertNil(selection?.queueAnchorIndex)
    }

    func testHistoryOperationsLeaveQueueStateAndRepeatAdvanceUnchanged() {
        var historyState = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 1,
            userQueue: [testSong("user-1")],
            truthAlbumQueue: [testSong("album-1"), testSong("album-2")],
            truthPlayNextQueue: [testSong("next-1")],
            truthUserQueue: [testSong("user-1")],
            currentSong: testSong("album-2")
        )
        var controlState = historyState
        var history = AudioPlayerBackHistoryState()

        history.recordTransition(
            from: historyState.currentSong,
            to: testSong("detached"),
            queue: historyState.queue,
            currentIndex: historyState.currentIndex
        )
        _ = history.popPrevious(in: historyState.queue)

        let historyAction = historyState.advance(
            repeatMode: .all,
            isShuffled: false,
            triggeredByUser: false
        )
        let controlAction = controlState.advance(
            repeatMode: .all,
            isShuffled: false,
            triggeredByUser: false
        )

        XCTAssertEqual(historyAction, controlAction)
        XCTAssertEqual(historyState, controlState)
    }

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

    func testPreviousMovesToPreviousAlbumTrack() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 1,
            currentSong: testSong("album-2")
        )

        let song = state.previous()

        XCTAssertEqual(song?.id, "album-1")
        XCTAssertEqual(state.currentIndex, 0)
        state.currentSong = song
        XCTAssertNil(state.previous())
    }

    func testPreviousReturnsQueueAnchorBeforeMovingBackwardFromDetachedSong() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("pink-floyd"), testSong("album-3")],
            currentIndex: 1,
            currentSong: testSong("detached-selection")
        )

        let anchoredSong = state.previous()

        XCTAssertEqual(anchoredSong?.id, "pink-floyd")
        XCTAssertEqual(state.currentIndex, 1)

        state.currentSong = anchoredSong
        let earlierSong = state.previous()

        XCTAssertEqual(earlierSong?.id, "album-1")
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testPreviousCanReturnToFirstQueueTrackFromDetachedSong() {
        var state = makeQueueState(
            queue: [testSong("pink-floyd"), testSong("album-2")],
            currentIndex: 0,
            currentSong: testSong("detached-selection")
        )

        let song = state.previous()

        XCTAssertEqual(song?.id, "pink-floyd")
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testPeekNextSongPrioritizesPlayNextThenAlbumThenUserQueue() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 0,
            playNextQueue: [testSong("next-1")],
            userQueue: [testSong("user-1")]
        )

        XCTAssertEqual(state.peekNextSong()?.id, "next-1")

        state.playNextQueue = []
        XCTAssertEqual(state.peekNextSong()?.id, "album-2")

        state.currentIndex = 1
        XCTAssertEqual(state.peekNextSong()?.id, "user-1")

        state.userQueue = []
        XCTAssertNil(state.peekNextSong())
    }

    func testAdvancePreparedQueueStateConsumesVisiblePlayNextOnly() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            playNextQueue: [testSong("next-1"), testSong("next-2")],
            truthPlayNextQueue: [testSong("next-1"), testSong("next-2")]
        )

        state.advancePreparedQueueState(repeatMode: .off)

        XCTAssertEqual(state.playNextQueue.map(\.id), ["next-2"])
        XCTAssertEqual(state.truthPlayNextQueue.map(\.id), ["next-1", "next-2"])
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testAdvancePreparedQueueStateAdvancesAlbumQueue() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 0
        )

        state.advancePreparedQueueState(repeatMode: .off)

        XCTAssertEqual(state.currentIndex, 1)
    }

    func testAdvancePreparedQueueStateAppendsUserQueueAtAlbumEnd() {
        var state = makeQueueState(
            queue: [testSong("album-1")],
            currentIndex: 0,
            userQueue: [testSong("user-1")]
        )

        state.advancePreparedQueueState(repeatMode: .off)

        XCTAssertEqual(state.queue.map(\.id), ["album-1", "user-1"])
        XCTAssertEqual(state.userQueue.map(\.id), [])
        XCTAssertEqual(state.currentIndex, 1)
    }

    func testAdvancePreparedQueueStateWrapsAlbumQueueForRepeatAll() {
        var state = makeQueueState(
            queue: [testSong("album-1"), testSong("album-2")],
            currentIndex: 1
        )

        state.advancePreparedQueueState(repeatMode: .all)

        XCTAssertEqual(state.currentIndex, 0)
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
