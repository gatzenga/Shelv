import XCTest

final class LibraryPlaybackQueueBuilderTests: XCTestCase {
    func testOrderedPlaybackPreservesVisibleAlbumOrderAndAppliesLimit() async {
        let albums = [Album(id: "a", name: "A"), Album(id: "b", name: "B"), Album(id: "c", name: "C")]
        let songsByAlbumID = [
            "a": [song("a1", albumID: "a"), song("a2", albumID: "a")],
            "b": [song("b1", albumID: "b"), song("b2", albumID: "b")],
            "c": [song("c1", albumID: "c")],
        ]
        let recorder = AlbumLoadRecorder()

        let queue = await LibraryPlaybackQueueBuilder.songs(
            from: albums,
            shuffled: false,
            maximumSongCount: 3,
            maximumConcurrentAlbumLoads: 2
        ) { album in
            await recorder.record(album.id)
            return songsByAlbumID[album.id] ?? []
        }

        XCTAssertEqual(queue.map(\.id), ["a1", "a2", "b1"])
        let loadedAlbumIDs = await recorder.loadedIDs()
        XCTAssertEqual(loadedAlbumIDs, Set(["a", "b"]))
    }

    func testOrderedPlaybackUsesDefaultFiveHundredSongLimit() async {
        let album = Album(id: "a", name: "A")
        let albumSongs = (0..<600).map { song("song-\($0)", albumID: album.id) }

        let queue = await LibraryPlaybackQueueBuilder.songs(
            from: [album],
            shuffled: false
        ) { _ in
            albumSongs
        }

        XCTAssertEqual(queue.count, 500)
        XCTAssertEqual(queue.first?.id, "song-0")
        XCTAssertEqual(queue.last?.id, "song-499")
    }

    func testShuffleLoadsEveryVisibleAlbumBeforeSampling() async {
        let albums = [Album(id: "a", name: "A"), Album(id: "b", name: "B"), Album(id: "c", name: "C")]
        let songsByAlbumID = [
            "a": [song("a1", albumID: "a"), song("a2", albumID: "a")],
            "b": [song("b1", albumID: "b"), song("b2", albumID: "b")],
            "c": [song("c1", albumID: "c"), song("c2", albumID: "c")],
        ]
        let allSongIDs = Set(songsByAlbumID.values.flatMap { $0 }.map(\.id))
        let recorder = AlbumLoadRecorder()

        let queue = await LibraryPlaybackQueueBuilder.songs(
            from: albums,
            shuffled: true,
            maximumSongCount: 3,
            maximumConcurrentAlbumLoads: 2
        ) { album in
            await recorder.record(album.id)
            return songsByAlbumID[album.id] ?? []
        }

        XCTAssertEqual(queue.count, 3)
        XCTAssertTrue(Set(queue.map(\.id)).isSubset(of: allSongIDs))
        let loadedAlbumIDs = await recorder.loadedIDs()
        XCTAssertEqual(loadedAlbumIDs, Set(albums.map(\.id)))
    }
}

private actor AlbumLoadRecorder {
    private var ids: Set<String> = []

    func record(_ id: String) {
        ids.insert(id)
    }

    func loadedIDs() -> Set<String> {
        ids
    }
}

private func song(_ id: String, albumID: String) -> Song {
    Song(id: id, title: id, albumId: albumID)
}
