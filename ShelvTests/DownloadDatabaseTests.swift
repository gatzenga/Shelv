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
        await database.markAlbumDownloaded(id: "album-a", name: "Album A", serverId: "server-a")

        await database.deleteAll()

        let serverASongs = await database.allSongIds(serverId: "server-a")
        let serverBSongs = await database.allSongIds(serverId: "server-b")
        let playlistIds = await database.loadDownloadedPlaylistIds(serverId: "server-a")
        let albumIds = await database.managedAlbumIds(serverId: "server-a")
        XCTAssertTrue(serverASongs.isEmpty)
        XCTAssertTrue(serverBSongs.isEmpty)
        XCTAssertTrue(playlistIds.isEmpty)
        XCTAssertTrue(albumIds.isEmpty)
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

        await database.noteCollectionDetail(
            kind: .playlist,
            id: "shared-playlist",
            serverId: "server-a",
            signature: "playlist-signature"
        )
        await database.unmarkPlaylistDownloaded(id: "shared-playlist", serverId: "server-a")
        let remainingA = await database.loadDownloadedPlaylistIds(serverId: "server-a")
        let remainingB = await database.loadDownloadedPlaylistIds(serverId: "server-b")
        let refreshAfterRemark = await database.collectionRefreshCandidates(
            kind: .playlist,
            observations: [
                DownloadCollectionObservation(
                    id: "shared-playlist",
                    signature: "playlist-signature"
                )
            ],
            serverId: "server-a",
            managedIds: ["shared-playlist"],
            staleBefore: nil,
            staleLimit: 0
        )
        XCTAssertTrue(remainingA.isEmpty)
        XCTAssertEqual(remainingB, ["shared-playlist"])
        XCTAssertEqual(refreshAfterRemark, ["shared-playlist"])
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

    func testObservedSongRefreshesMetadataWithoutReplacingLocalAudioProperties() async throws {
        let database = await makeDatabase()
        let original = record(
            songId: "song-1",
            serverId: "server-a",
            albumId: "album-a",
            filePath: "/local/song.flac"
        )
        await database.upsert(original)

        let observed = Song(
            id: "song-1",
            title: "Renamed Song",
            artist: "Renamed Artist",
            artistId: "artist-new",
            album: "Renamed Album",
            albumId: "album-a",
            track: 7,
            discNumber: 2,
            duration: 241,
            coverArt: "cover-new",
            year: 2025,
            genre: "Alternative",
            playCount: 12,
            starred: Date(timeIntervalSince1970: 1_800_000_000),
            contentType: "audio/ogg",
            suffix: "opus",
            fileSize: 9_999,
            bitRate: 320,
            bitDepth: 24,
            samplingRate: 96_000,
            channelCount: 6,
            bpm: 123,
            displayAlbumArtist: "Renamed Album Artist",
            explicitStatus: "explicit",
            replayGain: ReplayGain(
                trackGain: -4.5,
                albumGain: -3.5,
                trackPeak: nil,
                albumPeak: nil,
                baseGain: nil
            )
        )

        let update = await database.updateObservedSongs(
            [observed],
            serverId: "server-a"
        )
        let refreshed = await database.record(
            songId: "song-1",
            serverId: "server-a"
        )

        XCTAssertEqual(update.changes.count, 1)
        XCTAssertEqual(refreshed?.title, "Renamed Song")
        XCTAssertEqual(refreshed?.artistName, "Renamed Artist")
        XCTAssertEqual(refreshed?.artistId, "artist-new")
        XCTAssertEqual(refreshed?.albumTitle, "Renamed Album")
        XCTAssertEqual(refreshed?.albumArtistName, "Renamed Album Artist")
        XCTAssertEqual(refreshed?.track, 7)
        XCTAssertEqual(refreshed?.disc, 2)
        XCTAssertEqual(refreshed?.duration, 241)
        XCTAssertEqual(refreshed?.coverArtId, "cover-new")
        XCTAssertEqual(refreshed?.year, 2025)
        XCTAssertEqual(refreshed?.genre, "Alternative")
        XCTAssertEqual(refreshed?.playCount, 12)
        XCTAssertEqual(refreshed?.explicitStatus, "explicit")
        XCTAssertEqual(refreshed?.bpm, 123)
        XCTAssertEqual(refreshed?.replayGainTrackGain, -4.5)
        XCTAssertEqual(refreshed?.replayGainAlbumGain, -3.5)
        XCTAssertEqual(refreshed?.isFavorite, original.isFavorite)

        XCTAssertEqual(refreshed?.filePath, original.filePath)
        XCTAssertEqual(refreshed?.bytes, original.bytes)
        XCTAssertEqual(refreshed?.fileExtension, original.fileExtension)
        XCTAssertEqual(refreshed?.contentType, original.contentType)
        XCTAssertEqual(refreshed?.bitRate, original.bitRate)
        XCTAssertEqual(refreshed?.bitDepth, original.bitDepth)
        XCTAssertEqual(refreshed?.samplingRate, original.samplingRate)
        XCTAssertEqual(refreshed?.channelCount, original.channelCount)
        XCTAssertEqual(refreshed?.addedAt, original.addedAt)
    }

    func testAlbumSummaryRefreshIsServerScoped() async throws {
        let database = await makeDatabase()
        await database.upsert(record(
            songId: "song-a",
            serverId: "server-a",
            albumId: "album-shared"
        ))
        await database.upsert(record(
            songId: "song-b",
            serverId: "server-b",
            albumId: "album-shared"
        ))

        let album = Album(
            id: "album-shared",
            name: "Renamed Album",
            artist: "Renamed Artist",
            artistId: "artist-new",
            coverArt: "album-cover-new",
            songCount: 1,
            duration: 200,
            year: 2025,
            genre: "Jazz"
        )
        let update = await database.updateAlbumSummaries(
            [album],
            serverId: "server-a"
        )
        let serverA = await database.record(songId: "song-a", serverId: "server-a")
        let serverB = await database.record(songId: "song-b", serverId: "server-b")

        XCTAssertEqual(update.changes.count, 1)
        XCTAssertEqual(serverA?.albumTitle, "Renamed Album")
        XCTAssertEqual(serverA?.albumArtistName, "Renamed Artist")
        XCTAssertEqual(serverA?.artistName, "Renamed Artist")
        XCTAssertEqual(serverA?.artistId, "artist-new")
        XCTAssertEqual(serverA?.albumCoverArtId, "album-cover-new")
        XCTAssertEqual(serverA?.coverArtId, "cover-a")
        XCTAssertEqual(serverA?.year, 2025)
        XCTAssertEqual(serverA?.genre, "Jazz")

        XCTAssertEqual(serverB?.albumTitle, "Album")
        XCTAssertEqual(serverB?.artistName, "Artist")
        XCTAssertEqual(serverB?.albumCoverArtId, "album-cover-a")
    }

    func testManagedAlbumsAndCollectionRefreshStateStayServerScoped() async throws {
        let database = await makeDatabase()
        await database.markAlbumDownloaded(
            id: "album-shared",
            name: "Server A Album",
            serverId: "server-a"
        )
        await database.markAlbumDownloaded(
            id: "album-shared",
            name: "Server B Album",
            serverId: "server-b"
        )
        await database.markPlaylistDownloaded(
            id: "playlist-a",
            name: "Server A Playlist",
            serverId: "server-a"
        )
        await database.noteCollectionDetail(
            kind: .album,
            id: "album-shared",
            serverId: "server-a",
            signature: "signature-a",
            date: 100
        )

        let unchanged = await database.collectionRefreshCandidates(
            kind: .album,
            observations: [
                DownloadCollectionObservation(
                    id: "album-shared",
                    signature: "signature-a"
                )
            ],
            serverId: "server-a",
            managedIds: ["album-shared"],
            staleBefore: nil,
            staleLimit: 0
        )
        let changedOnOtherServer = await database.collectionRefreshCandidates(
            kind: .album,
            observations: [
                DownloadCollectionObservation(
                    id: "album-shared",
                    signature: "signature-b"
                )
            ],
            serverId: "server-b",
            managedIds: ["album-shared"],
            staleBefore: nil,
            staleLimit: 0
        )

        XCTAssertTrue(unchanged.isEmpty)
        XCTAssertEqual(changedOnOtherServer, ["album-shared"])

        await database.deleteAllForServer("server-a")
        let remainingServerAAlbums = await database.managedAlbumIds(
            serverId: "server-a"
        )
        let remainingServerBAlbums = await database.managedAlbumIds(
            serverId: "server-b"
        )
        let remainingServerAPlaylists = await database.loadDownloadedPlaylistIds(
            serverId: "server-a"
        )
        XCTAssertTrue(remainingServerAAlbums.isEmpty)
        XCTAssertEqual(remainingServerBAlbums, ["album-shared"])
        XCTAssertTrue(remainingServerAPlaylists.isEmpty)
    }

    func testCollectionRefreshCandidatesPrioritizeChangesThenOldestStaleDetails() async throws {
        let database = await makeDatabase()
        let managedIds: Set<String> = ["album-a", "album-b", "album-c"]
        await database.noteCollectionDetail(
            kind: .album,
            id: "album-a",
            serverId: "server-a",
            signature: "same-a",
            date: 100
        )
        await database.noteCollectionDetail(
            kind: .album,
            id: "album-b",
            serverId: "server-a",
            signature: "same-b",
            date: 200
        )
        await database.noteCollectionDetail(
            kind: .album,
            id: "album-c",
            serverId: "server-a",
            signature: "old-c",
            date: 300
        )

        let candidates = await database.collectionRefreshCandidates(
            kind: .album,
            observations: [
                DownloadCollectionObservation(id: "album-a", signature: "same-a"),
                DownloadCollectionObservation(id: "album-b", signature: "same-b"),
                DownloadCollectionObservation(id: "album-c", signature: "new-c"),
            ],
            serverId: "server-a",
            managedIds: managedIds,
            staleBefore: 250,
            staleLimit: 1
        )

        XCTAssertEqual(candidates, ["album-c", "album-a"])
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
                        artistName: String = "Artist",
                        filePath: String? = nil) -> DownloadRecord {
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
            filePath: filePath ?? tempDir.appendingPathComponent("\(songId).mp3").path,
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
