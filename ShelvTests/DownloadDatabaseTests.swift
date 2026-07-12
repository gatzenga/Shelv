import XCTest

final class DownloadDatabaseTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelvDownloadDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testPlaylistOfflineMarkerIsExplicitAndNotInferredFromDownloadedSongs() async throws {
        let database = await makeDatabase()
        let serverId = "server-a"

        await database.upsert(record(songId: "song-1", serverId: serverId, albumId: "album-a"))
        await database.upsert(record(songId: "song-2", serverId: serverId, albumId: "album-a"))

        let downloadedSongIds = await database.allSongIds(serverId: serverId)
        let playlistIdsBeforeMarker = await database.loadDownloadedPlaylistIds(serverId: serverId)
        XCTAssertEqual(downloadedSongIds, ["song-1", "song-2"])
        XCTAssertTrue(playlistIdsBeforeMarker.isEmpty)

        await database.markPlaylistDownloaded(id: "playlist-a", name: "Road", serverId: serverId)

        let playlistIdsAfterMarker = await database.loadDownloadedPlaylistIds(serverId: serverId)
        XCTAssertEqual(playlistIdsAfterMarker, ["playlist-a"])
    }

    func testDeletingSongRemovesTheGlobalDownloadEvenWhenAPlaylistIsMarkedOffline() async throws {
        let database = await makeDatabase()
        let serverId = "server-a"

        await database.markPlaylistDownloaded(id: "playlist-a", name: "Road", serverId: serverId)
        await database.upsert(record(songId: "song-1", serverId: serverId, albumId: "album-a"))

        let isDownloadedBeforeDelete = await database.isDownloaded(songId: "song-1", serverId: serverId)
        XCTAssertTrue(isDownloadedBeforeDelete)

        await database.delete(songId: "song-1", serverId: serverId)

        let isDownloadedAfterDelete = await database.isDownloaded(songId: "song-1", serverId: serverId)
        let recordAfterDelete = await database.record(songId: "song-1", serverId: serverId)
        XCTAssertFalse(isDownloadedAfterDelete)
        XCTAssertNil(recordAfterDelete)
    }

    func testDeleteAllClearsDownloadsAndPlaylistMarkers() async throws {
        let database = await makeDatabase()

        await database.upsert(record(songId: "song-1", serverId: "server-a", albumId: "album-a"))
        await database.upsert(record(songId: "song-2", serverId: "server-b", albumId: "album-b"))
        await database.markPlaylistDownloaded(id: "playlist-a", name: "Road", serverId: "server-a")

        await database.deleteAll()

        let serverASongs = await database.allSongIds(serverId: "server-a")
        let serverBSongs = await database.allSongIds(serverId: "server-b")
        let playlistIds = await database.loadDownloadedPlaylistIds(serverId: "server-a")
        XCTAssertTrue(serverASongs.isEmpty)
        XCTAssertTrue(serverBSongs.isEmpty)
        XCTAssertTrue(playlistIds.isEmpty)
    }

    func testSongCountsByAlbumAreScopedToServer() async throws {
        let database = await makeDatabase()

        await database.upsert(record(songId: "song-1", serverId: "server-a", albumId: "album-a"))
        await database.upsert(record(songId: "song-2", serverId: "server-a", albumId: "album-a"))
        await database.upsert(record(songId: "song-3", serverId: "server-a", albumId: "album-b"))
        await database.upsert(record(songId: "song-4", serverId: "server-b", albumId: "album-a"))

        let serverACounts = await database.songCountsByAlbum(serverId: "server-a")
        let serverBCounts = await database.songCountsByAlbum(serverId: "server-b")

        XCTAssertEqual(serverACounts, ["album-a": 2, "album-b": 1])
        XCTAssertEqual(serverBCounts, ["album-a": 1])
    }

    func testPlaylistMarkersWithSameIDStayScopedToTheirServer() async throws {
        let database = await makeDatabase()

        await database.markPlaylistDownloaded(id: "shared-playlist", name: "Road", serverId: "server-a")
        await database.markPlaylistDownloaded(id: "shared-playlist", name: "Focus", serverId: "server-b")

        let serverA = await database.loadDownloadedPlaylistIds(serverId: "server-a")
        let serverB = await database.loadDownloadedPlaylistIds(serverId: "server-b")

        XCTAssertEqual(serverA, ["shared-playlist"])
        XCTAssertEqual(serverB, ["shared-playlist"])

        await database.unmarkPlaylistDownloaded(id: "shared-playlist", serverId: "server-a")
        let remainingA = await database.loadDownloadedPlaylistIds(serverId: "server-a")
        let remainingB = await database.loadDownloadedPlaylistIds(serverId: "server-b")
        XCTAssertTrue(remainingA.isEmpty)
        XCTAssertEqual(remainingB, ["shared-playlist"])
    }

    func testLegacyMarkerCanBeAdoptedByEveryMatchingServer() async throws {
        let database = await makeDatabase()
        await database.markPlaylistDownloaded(id: "shared-playlist", name: "Legacy", serverId: "")

        await database.adoptLegacyPlaylistMarkers(
            serverId: "server-a",
            playlistIds: ["shared-playlist"]
        )
        await database.adoptLegacyPlaylistMarkers(
            serverId: "server-b",
            playlistIds: ["shared-playlist"]
        )

        let serverA = await database.loadDownloadedPlaylistIds(serverId: "server-a")
        let serverB = await database.loadDownloadedPlaylistIds(serverId: "server-b")
        XCTAssertEqual(serverA, ["shared-playlist"])
        XCTAssertEqual(serverB, ["shared-playlist"])
    }

    func testDownloadedRecordsSortByDiscBeforeTrack() async throws {
        let database = await makeDatabase()
        var discTwo = record(songId: "disc-2-track-1", serverId: "server-a", albumId: "album-a")
        discTwo.disc = 2
        discTwo.track = 1
        var discOne = record(songId: "disc-1-track-2", serverId: "server-a", albumId: "album-a")
        discOne.disc = 1
        discOne.track = 2

        await database.upsert(discTwo)
        await database.upsert(discOne)

        let records = await database.allRecords(serverId: "server-a")
        XCTAssertEqual(records.map(\.songId), ["disc-1-track-2", "disc-2-track-1"])
    }

    private func makeDatabase() async -> DownloadDatabase {
        let url = tempDir.appendingPathComponent("downloads-\(UUID().uuidString).db")
        let database = DownloadDatabase(testDatabaseURL: url)
        await database.setup()
        return database
    }

    private func record(songId: String,
                        serverId: String,
                        albumId: String,
                        artistId: String? = "artist-a",
                        title: String = "Song",
                        albumTitle: String = "Album",
                        artistName: String = "Artist") -> DownloadRecord {
        DownloadRecord(
            songId: songId,
            serverId: serverId,
            albumId: albumId,
            artistId: artistId,
            title: title,
            albumTitle: albumTitle,
            artistName: artistName,
            track: 1,
            disc: 1,
            duration: 180,
            year: 2026,
            genre: "Rock",
            playCount: 7,
            explicitStatus: nil,
            bytes: 1_024,
            coverArtId: "cover-a",
            artistCoverArtId: "artist-cover-a",
            albumArtistName: artistName,
            albumCoverArtId: "album-cover-a",
            isFavorite: false,
            filePath: tempDir.appendingPathComponent("\(songId).mp3").path,
            fileExtension: "mp3",
            contentType: "audio/mpeg",
            bitRate: 192,
            bitDepth: nil,
            samplingRate: 44_100,
            channelCount: 2,
            bpm: nil,
            replayGainTrackGain: nil,
            replayGainAlbumGain: nil,
            addedAt: 1_700_000_000
        )
    }
}
