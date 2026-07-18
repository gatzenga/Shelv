import XCTest

final class DownloadCatalogBuilderTests: XCTestCase {
    private let serverID = "server-a"
    private let artistCovers = [
        "Alpha": "alpha-cover",
        "Beta": "beta-cover",
        "Charlie": "charlie-cover",
        "Zulu": "zulu-cover",
    ]

    func testIncrementalApplicationMatchesAuthoritativeRebuildAcrossChunks() {
        let initial = [
            record(
                songID: "song-1",
                albumID: "album-a",
                albumTitle: "Alpha Album",
                artistName: "Lead feat. Guest",
                albumArtistName: "Alpha",
                bytes: 100,
                track: 2
            ),
            record(
                songID: "song-2",
                albumID: "album-b",
                albumTitle: "Beta Album",
                artistName: "Beta",
                albumArtistName: "Beta",
                bytes: 200,
                track: 1
            ),
        ]
        let firstChunk = [
            record(
                songID: "song-3",
                albumID: "album-a",
                albumTitle: "Alpha Album",
                artistName: "Alpha",
                albumArtistName: "Alpha",
                bytes: 300,
                isFavorite: true,
                track: 1
            ),
            record(
                songID: "song-4",
                albumID: "album-c",
                albumTitle: "Charlie Album",
                artistName: "Charlie",
                albumArtistName: "Charlie",
                bytes: 400,
                track: 1
            ),
        ]
        let secondChunk = [
            record(
                songID: "song-1",
                albumID: "album-z",
                albumTitle: "Zulu Album",
                artistName: "Zulu / Guest",
                albumArtistName: "Zulu",
                bytes: 150,
                isFavorite: true,
                track: 1
            ),
            record(
                songID: "ignored-foreign-song",
                serverID: "server-b",
                albumID: "foreign-album",
                albumTitle: "Foreign Album",
                artistName: "Foreign Artist",
                bytes: 999,
                track: 1
            ),
        ]

        var incremental = DownloadCatalogBuilder.rebuilding(
            initial,
            serverId: serverID,
            artistCoverByName: artistCovers
        )
        incremental = DownloadCatalogBuilder.applying(
            firstChunk,
            to: incremental,
            serverId: serverID,
            artistCoverByName: artistCovers
        )
        incremental = DownloadCatalogBuilder.applying(
            secondChunk,
            to: incremental,
            serverId: serverID,
            artistCoverByName: artistCovers
        )

        let authoritative = DownloadCatalogBuilder.rebuilding(
            initial + firstChunk + secondChunk,
            serverId: serverID,
            artistCoverByName: artistCovers
        )

        XCTAssertEqual(incremental, authoritative)
        XCTAssertEqual(
            incremental.recordsByAlbumId["album-a"]?.map(\.songId),
            ["song-3"]
        )
        XCTAssertEqual(incremental.recordsByAlbumId["album-z"]?.map(\.songId), ["song-1"])
        XCTAssertNil(incremental.songById["ignored-foreign-song"])
    }

    func testUpsertReplacesBytesAndFavoriteStateWithoutDuplicatingSong() {
        let original = record(
            songID: "song-1",
            albumID: "album-a",
            albumTitle: "Album",
            artistName: "Lead feat. Guest",
            bytes: 100,
            isFavorite: false,
            track: 1
        )
        var snapshot = DownloadCatalogBuilder.rebuilding(
            [original],
            serverId: serverID,
            artistCoverByName: [:]
        )

        let favoritedReplacement = record(
            songID: "song-1",
            albumID: "album-a",
            title: "Revised Song",
            albumTitle: "Album",
            artistName: "Lead feat. Guest",
            bytes: 512,
            isFavorite: true,
            track: 1
        )
        snapshot = DownloadCatalogBuilder.applying(
            [favoritedReplacement],
            to: snapshot,
            serverId: serverID,
            artistCoverByName: [:]
        )

        XCTAssertEqual(snapshot.songs.count, 1)
        XCTAssertEqual(snapshot.songById["song-1"]?.title, "Revised Song")
        XCTAssertEqual(snapshot.recordsByAlbumId["album-a"]?.count, 1)
        XCTAssertEqual(snapshot.totalBytes, 512)
        XCTAssertEqual(snapshot.uiState.totalBytes, 512)
        XCTAssertEqual(snapshot.favoriteSongs.map(\.songId), ["song-1"])
        XCTAssertEqual(snapshot.uiState.albumDownloadedCounts["album-a"], 1)

        let nonFavoriteReplacement = record(
            songID: "song-1",
            albumID: "album-a",
            albumTitle: "Album",
            artistName: "Solo",
            bytes: 64,
            isFavorite: false,
            track: 1
        )
        snapshot = DownloadCatalogBuilder.applying(
            [nonFavoriteReplacement],
            to: snapshot,
            serverId: serverID,
            artistCoverByName: [:]
        )

        XCTAssertEqual(snapshot.songs.count, 1)
        XCTAssertEqual(snapshot.totalBytes, 64)
        XCTAssertTrue(snapshot.favoriteSongs.isEmpty)
        XCTAssertEqual(snapshot.artists.map(\.name), ["Solo"])
        XCTAssertFalse(snapshot.uiState.artistBadgeNames.contains("Lead"))
        XCTAssertFalse(snapshot.uiState.artistBadgeNames.contains("Guest"))
        XCTAssertTrue(snapshot.uiState.artistBadgeNames.contains("Solo"))
    }

    func testEarlierTrackChangingAlbumArtistMatchesAuthoritativeRebuild() {
        let laterTrack = record(
            songID: "song-2",
            albumID: "album-a",
            albumTitle: "Album",
            artistName: "Performer",
            albumArtistName: "Alpha",
            bytes: 100,
            track: 2
        )
        let earlierTrack = record(
            songID: "song-1",
            albumID: "album-a",
            albumTitle: "Album",
            artistName: "Performer",
            albumArtistName: "Beta",
            bytes: 100,
            track: 1
        )

        let initial = DownloadCatalogBuilder.rebuilding(
            [laterTrack],
            serverId: serverID,
            artistCoverByName: artistCovers
        )
        let incremental = DownloadCatalogBuilder.applying(
            [earlierTrack],
            to: initial,
            serverId: serverID,
            artistCoverByName: artistCovers
        )
        let authoritative = DownloadCatalogBuilder.rebuilding(
            [laterTrack, earlierTrack],
            serverId: serverID,
            artistCoverByName: artistCovers
        )

        XCTAssertEqual(incremental, authoritative)
        XCTAssertEqual(incremental.artists.map(\.name), ["Beta"])
        XCTAssertFalse(incremental.uiState.artistBadgeNames.contains("Alpha"))
    }

    private func record(
        songID: String,
        serverID: String = "server-a",
        albumID: String,
        title: String = "Song",
        albumTitle: String,
        artistName: String,
        albumArtistName: String? = nil,
        bytes: Int64,
        isFavorite: Bool = false,
        track: Int?,
        disc: Int? = 1
    ) -> DownloadRecord {
        DownloadRecord(
            songId: songID,
            serverId: serverID,
            albumId: albumID,
            artistId: "artist-\(artistName)",
            title: title,
            albumTitle: albumTitle,
            artistName: artistName,
            track: track,
            disc: disc,
            duration: 180,
            year: 2026,
            genre: "Rock",
            playCount: 7,
            explicitStatus: nil,
            bytes: bytes,
            coverArtId: "cover-\(albumID)",
            artistCoverArtId: "cover-\(artistName)",
            albumArtistName: albumArtistName,
            albumCoverArtId: "album-cover-\(albumID)",
            isFavorite: isFavorite,
            filePath: "/tmp/\(songID).mp3",
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
