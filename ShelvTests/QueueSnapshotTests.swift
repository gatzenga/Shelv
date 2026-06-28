import XCTest
@testable import Shelv

final class QueueSnapshotTests: XCTestCase {
    func testFlattenedForSubsonicPreservesPlaybackOrderAndRemovesDuplicates() {
        let snapshot = makeSnapshot(
            queue: [song("album-1"), song("album-2"), song("album-3"), song("duplicate")],
            currentIndex: 1,
            playNextQueue: [song("next-1"), song("duplicate"), song("next-2")],
            userQueue: [song("user-1"), song("album-3"), song("user-2")],
            currentSongId: "album-2",
            isShuffled: true,
            repeatMode: RepeatMode.all.rawValue
        )

        let flattened = snapshot.flattenedForSubsonic()

        XCTAssertEqual(
            flattened.queue.map(\.id),
            ["album-2", "next-1", "duplicate", "next-2", "album-3", "user-1", "user-2"]
        )
        XCTAssertEqual(flattened.currentIndex, 0)
        XCTAssertEqual(flattened.currentSongId, "album-2")
        XCTAssertTrue(flattened.playNextQueue.isEmpty)
        XCTAssertTrue(flattened.userQueue.isEmpty)
        XCTAssertTrue(flattened.truthAlbumQueue.isEmpty)
        XCTAssertTrue(flattened.truthPlayNextQueue.isEmpty)
        XCTAssertTrue(flattened.truthUserQueue.isEmpty)
        XCTAssertTrue(flattened.isShuffled)
        XCTAssertEqual(flattened.repeatMode, RepeatMode.all.rawValue)
        XCTAssertEqual(flattened.serverId, snapshot.serverId)
        XCTAssertEqual(flattened.changedAt, snapshot.changedAt)
    }

    func testSignatureIgnoresDeviceLocalMetadata() {
        let first = makeSnapshot(
            queue: [song("a"), song("b")],
            currentIndex: 0,
            playNextQueue: [song("next")],
            userQueue: [song("user")],
            currentSongId: "a",
            isShuffled: false,
            repeatMode: RepeatMode.off.rawValue,
            serverId: "server-a",
            changedAt: 10
        )
        let second = makeSnapshot(
            queue: [song("a"), song("b")],
            currentIndex: 1,
            playNextQueue: [song("next")],
            userQueue: [song("user")],
            currentSongId: "a",
            isShuffled: true,
            repeatMode: RepeatMode.one.rawValue,
            serverId: "server-b",
            changedAt: 99
        )

        XCTAssertEqual(first.signature, second.signature)
    }

    func testSignatureChangesWhenPlaybackContentChanges() {
        let base = makeSnapshot(
            queue: [song("a"), song("b")],
            playNextQueue: [song("next")],
            userQueue: [song("user")],
            currentSongId: "a"
        )
        let reordered = makeSnapshot(
            queue: [song("b"), song("a")],
            playNextQueue: [song("next")],
            userQueue: [song("user")],
            currentSongId: "a"
        )
        let differentCurrentSong = makeSnapshot(
            queue: [song("a"), song("b")],
            playNextQueue: [song("next")],
            userQueue: [song("user")],
            currentSongId: "b"
        )

        XCTAssertNotEqual(base.signature, reordered.signature)
        XCTAssertNotEqual(base.signature, differentCurrentSong.signature)
    }

    func testIsEmptyChecksAllQueueBuckets() {
        XCTAssertTrue(makeSnapshot(queue: [], playNextQueue: [], userQueue: []).isEmpty)
        XCTAssertFalse(makeSnapshot(queue: [song("a")], playNextQueue: [], userQueue: []).isEmpty)
        XCTAssertFalse(makeSnapshot(queue: [], playNextQueue: [song("next")], userQueue: []).isEmpty)
        XCTAssertFalse(makeSnapshot(queue: [], playNextQueue: [], userQueue: [song("user")]).isEmpty)
    }
}

private func song(_ id: String) -> Song {
    Song(id: id, title: "Song \(id)")
}

private func makeSnapshot(
    queue: [Song],
    currentIndex: Int = 0,
    playNextQueue: [Song],
    userQueue: [Song],
    truthAlbumQueue: [Song]? = nil,
    truthPlayNextQueue: [Song]? = nil,
    truthUserQueue: [Song]? = nil,
    currentSongId: String? = nil,
    isShuffled: Bool = false,
    repeatMode: String = RepeatMode.off.rawValue,
    serverId: String = "server",
    changedAt: Double = 1_234
) -> QueueSnapshot {
    QueueSnapshot(
        queue: queue,
        currentIndex: currentIndex,
        playNextQueue: playNextQueue,
        userQueue: userQueue,
        truthAlbumQueue: truthAlbumQueue ?? queue,
        truthPlayNextQueue: truthPlayNextQueue ?? playNextQueue,
        truthUserQueue: truthUserQueue ?? userQueue,
        currentSongId: currentSongId ?? queue[safe: currentIndex]?.id,
        isShuffled: isShuffled,
        repeatMode: repeatMode,
        serverId: serverId,
        changedAt: changedAt
    )
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
