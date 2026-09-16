import XCTest

final class DownloadIdentityDatabaseTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelvDownloadIdentityDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testRebindAlbumIdentityMigratesAllSongsAndManagedAlbumAtomically() async throws {
        let database = await makeDatabase()
        let serverId = "server-a"
        let first = record(
            songId: "old-1",
            serverId: serverId,
            albumId: "old-album",
            title: "First",
            track: 1,
            filePath: "/downloads/first.flac"
        )
        let second = record(
            songId: "old-2",
            serverId: serverId,
            albumId: "old-album",
            title: "Second",
            track: 2,
            filePath: "/downloads/second.flac"
        )
        await database.upsert(first)
        await database.upsert(second)
        await database.markAlbumDownloaded(
            id: "old-album",
            name: "Old Album",
            serverId: serverId
        )

        var reboundFirst = first
        reboundFirst.songId = "new-1"
        reboundFirst.albumId = "new-album"
        reboundFirst.albumTitle = "New Album"

        var reboundSecond = second
        reboundSecond.songId = "new-2"
        reboundSecond.albumId = "new-album"
        reboundSecond.albumTitle = "New Album"

        let succeeded = await database.rebindAlbumIdentity(
            replacements: [
                .init(previous: first, updated: reboundFirst),
                .init(previous: second, updated: reboundSecond),
            ],
            serverId: serverId,
            oldAlbumId: "old-album",
            newAlbumId: "new-album",
            newAlbumName: "New Album",
            migrateManagedAlbum: true
        )

        XCTAssertTrue(succeeded)
        let oldFirst = await database.record(songId: "old-1", serverId: serverId)
        let oldSecond = await database.record(songId: "old-2", serverId: serverId)
        XCTAssertNil(oldFirst)
        XCTAssertNil(oldSecond)

        let storedFirst = await database.record(songId: "new-1", serverId: serverId)
        let storedSecond = await database.record(songId: "new-2", serverId: serverId)
        XCTAssertEqual(storedFirst?.filePath, first.filePath)
        XCTAssertEqual(storedFirst?.bytes, first.bytes)
        XCTAssertEqual(storedFirst?.addedAt, first.addedAt)
        XCTAssertEqual(storedSecond?.filePath, second.filePath)
        XCTAssertEqual(storedSecond?.bytes, second.bytes)
        XCTAssertEqual(storedSecond?.addedAt, second.addedAt)

        let managedAlbums = await database.managedAlbumIds(serverId: serverId)
        XCTAssertFalse(managedAlbums.contains("old-album"))
        XCTAssertTrue(managedAlbums.contains("new-album"))
    }

    func testRebindAlbumIdentityRollsBackEntireAlbumOnDestinationConflict() async throws {
        let database = await makeDatabase()
        let serverId = "server-a"
        let first = record(
            songId: "old-1",
            serverId: serverId,
            albumId: "old-album",
            title: "First",
            track: 1,
            filePath: "/downloads/first.flac"
        )
        let second = record(
            songId: "old-2",
            serverId: serverId,
            albumId: "old-album",
            title: "Second",
            track: 2,
            filePath: "/downloads/second.flac"
        )
        let conflictingDestination = record(
            songId: "new-2",
            serverId: serverId,
            albumId: "other-album",
            title: "Different Local Download",
            track: 9,
            filePath: "/downloads/conflict.flac"
        )
        await database.upsert(first)
        await database.upsert(second)
        await database.upsert(conflictingDestination)
        await database.markAlbumDownloaded(
            id: "old-album",
            name: "Old Album",
            serverId: serverId
        )

        var reboundFirst = first
        reboundFirst.songId = "new-1"
        reboundFirst.albumId = "new-album"

        var reboundSecond = second
        reboundSecond.songId = "new-2"
        reboundSecond.albumId = "new-album"

        let succeeded = await database.rebindAlbumIdentity(
            replacements: [
                .init(previous: first, updated: reboundFirst),
                .init(previous: second, updated: reboundSecond),
            ],
            serverId: serverId,
            oldAlbumId: "old-album",
            newAlbumId: "new-album",
            newAlbumName: "New Album",
            migrateManagedAlbum: true
        )

        XCTAssertFalse(succeeded)
        let oldFirst = await database.record(songId: "old-1", serverId: serverId)
        let oldSecond = await database.record(songId: "old-2", serverId: serverId)
        let unexpectedNewFirst = await database.record(songId: "new-1", serverId: serverId)
        XCTAssertNotNil(oldFirst)
        XCTAssertNotNil(oldSecond)
        XCTAssertNil(unexpectedNewFirst)

        let conflictAfter = await database.record(songId: "new-2", serverId: serverId)
        XCTAssertEqual(conflictAfter?.filePath, conflictingDestination.filePath)
        XCTAssertEqual(conflictAfter?.albumId, conflictingDestination.albumId)

        let managedAlbums = await database.managedAlbumIds(serverId: serverId)
        XCTAssertTrue(managedAlbums.contains("old-album"))
        XCTAssertFalse(managedAlbums.contains("new-album"))
    }

    private func makeDatabase() async -> DownloadDatabase {
        let url = tempDir.appendingPathComponent("downloads-\(UUID().uuidString).db")
        let database = DownloadDatabase(testDatabaseURL: url)
        await database.setup()
        return database
    }

    private func record(
        songId: String,
        serverId: String,
        albumId: String,
        title: String,
        track: Int,
        filePath: String
    ) -> DownloadRecord {
        DownloadRecord(
            songId: songId,
            serverId: serverId,
            albumId: albumId,
            artistId: "artist-a",
            title: title,
            albumTitle: "Old Album",
            artistName: "Artist",
            track: track,
            disc: 1,
            duration: 180,
            year: 2026,
            genre: "Rock",
            playCount: 1,
            explicitStatus: nil,
            bytes: 123_456,
            coverArtId: "cover-a",
            artistCoverArtId: "artist-cover-a",
            albumArtistName: "Artist",
            albumCoverArtId: "album-cover-a",
            isFavorite: false,
            filePath: filePath,
            fileExtension: "flac",
            contentType: "audio/flac",
            bitRate: 1_411,
            bitDepth: 24,
            samplingRate: 96_000,
            channelCount: 2,
            bpm: 100,
            replayGainTrackGain: -1,
            replayGainAlbumGain: -2,
            addedAt: 1_700_000_000
        )
    }
}
