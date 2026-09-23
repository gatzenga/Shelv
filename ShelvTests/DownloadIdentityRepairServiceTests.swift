import XCTest

final class DownloadIdentityRepairServiceTests: XCTestCase {
    func testLargeIdentityChurnRequiresAbsoluteAndRatioThresholds() {
        XCTAssertFalse(
            DownloadIdentityRepairPolicy.isLargeIdentityChurn(
                orphanedSongs: 19,
                totalSongs: 20
            )
        )
        XCTAssertFalse(
            DownloadIdentityRepairPolicy.isLargeIdentityChurn(
                orphanedSongs: 20,
                totalSongs: 100
            )
        )
        XCTAssertTrue(
            DownloadIdentityRepairPolicy.isLargeIdentityChurn(
                orphanedSongs: 20,
                totalSongs: 40
            )
        )
        XCTAssertTrue(
            DownloadIdentityRepairPolicy.isLargeIdentityChurn(
                orphanedSongs: 50,
                totalSongs: 100
            )
        )
    }

    func testMatchingAlbumPrefersSurvivingAlbumID() {
        let records = [
            makeRecord(songId: "old-1", albumId: "album-stable", track: 1),
            makeRecord(songId: "old-2", albumId: "album-stable", track: 2),
        ]
        let sameID = Album(
            id: "album-stable",
            name: "Renamed Album",
            artist: "Renamed Artist",
            songCount: 2
        )
        let metadataLookalike = Album(
            id: "album-other",
            name: "Old Album",
            artist: "Old Artist",
            songCount: 2
        )

        let match = DownloadIdentityRepairPolicy.matchingAlbum(
            for: records,
            in: [metadataLookalike, sameID]
        )

        XCTAssertEqual(match?.id, "album-stable")
    }

    func testMatchingAlbumRejectsAmbiguousMetadataCandidates() {
        let records = [
            makeRecord(songId: "old-1", albumId: "missing", track: 1),
            makeRecord(songId: "old-2", albumId: "missing", track: 2),
        ]
        let first = Album(
            id: "new-a",
            name: "Old Album",
            artist: "Old Artist",
            songCount: 2
        )
        let second = Album(
            id: "new-b",
            name: "Old Album",
            artist: "Old Artist",
            songCount: 2
        )

        XCTAssertNil(
            DownloadIdentityRepairPolicy.matchingAlbum(
                for: records,
                in: [first, second]
            )
        )
    }

    func testMatchAlbumRebindsUniqueReidentifiedSongs() {
        let records = [
            makeRecord(songId: "old-1", track: 1, duration: 180),
            makeRecord(songId: "old-2", title: "Second", track: 2, duration: 200),
        ]
        let songs = [
            Song(
                id: "new-2",
                title: "Second",
                albumId: "new-album",
                track: 2,
                discNumber: 1,
                duration: 201
            ),
            Song(
                id: "new-1",
                title: "First",
                albumId: "new-album",
                track: 1,
                discNumber: 1,
                duration: 179
            ),
        ]

        let matches = DownloadIdentityRepairPolicy.matchAlbum(
            records: records,
            songs: songs
        )

        XCTAssertEqual(matches?.count, 2)
        XCTAssertEqual(matches?.first?.0.songId, "old-1")
        XCTAssertEqual(matches?.first?.1.id, "new-1")
        XCTAssertEqual(matches?.last?.0.songId, "old-2")
        XCTAssertEqual(matches?.last?.1.id, "new-2")
    }

    func testMatchAlbumRejectsAmbiguousTracks() {
        let records = [
            makeRecord(songId: "old-1", track: 1, duration: 180),
            makeRecord(songId: "old-2", track: 1, duration: 180),
        ]
        let songs = [
            Song(
                id: "new-1",
                title: "First",
                track: 1,
                discNumber: 1,
                duration: 180
            ),
            Song(
                id: "new-2",
                title: "First",
                track: 1,
                discNumber: 1,
                duration: 180
            ),
        ]

        XCTAssertNil(
            DownloadIdentityRepairPolicy.matchAlbum(
                records: records,
                songs: songs
            )
        )
    }

    func testMatchAlbumRejectsDestinationSongAlreadyOwnedByAnotherRecord() {
        let record = makeRecord(songId: "old-1", track: 1, duration: 180)
        let song = Song(
            id: "new-1",
            title: "First",
            track: 1,
            discNumber: 1,
            duration: 180
        )

        XCTAssertNil(
            DownloadIdentityRepairPolicy.matchAlbum(
                records: [record],
                songs: [song],
                existingSongIds: ["new-1"]
            )
        )
    }

    func testReboundRecordPreservesDownloadedFileProperties() {
        let original = makeRecord(
            songId: "old-song",
            albumId: "old-album",
            track: 1,
            duration: 180
        )
        let remote = Song(
            id: "new-song",
            title: "Updated Title",
            artist: "Updated Artist",
            artistId: "new-artist",
            album: "Updated Album",
            albumId: "new-album",
            track: 1,
            discNumber: 1,
            duration: 181,
            coverArt: "new-cover",
            year: 2026,
            genre: "Alternative",
            playCount: 42,
            starred: Date(timeIntervalSince1970: 1_800_000_000),
            contentType: "audio/ogg",
            suffix: "opus",
            fileSize: 999,
            bitRate: 320,
            bitDepth: 32,
            samplingRate: 192_000,
            channelCount: 6,
            bpm: 123,
            displayAlbumArtist: "Updated Album Artist",
            explicitStatus: "explicit",
            replayGain: ReplayGain(
                trackGain: -4.5,
                albumGain: -3.5,
                trackPeak: nil,
                albumPeak: nil,
                baseGain: nil
            )
        )
        let album = DownloadAlbumMetadata(
            id: "new-album",
            name: "Updated Album",
            artist: "Updated Artist",
            artistId: "new-artist",
            coverArt: "new-album-cover",
            songCount: 1,
            duration: 181,
            year: 2026,
            genre: "Alternative"
        )

        let rebound = DownloadIdentityRepairPolicy.reboundRecord(
            original,
            to: remote,
            album: album
        )

        XCTAssertEqual(rebound.songId, "new-song")
        XCTAssertEqual(rebound.albumId, "new-album")
        XCTAssertEqual(rebound.artistId, "new-artist")
        XCTAssertEqual(rebound.title, "Updated Title")
        XCTAssertEqual(rebound.filePath, original.filePath)
        XCTAssertEqual(rebound.bytes, original.bytes)
        XCTAssertEqual(rebound.fileExtension, original.fileExtension)
        XCTAssertEqual(rebound.contentType, original.contentType)
        XCTAssertEqual(rebound.bitRate, original.bitRate)
        XCTAssertEqual(rebound.bitDepth, original.bitDepth)
        XCTAssertEqual(rebound.samplingRate, original.samplingRate)
        XCTAssertEqual(rebound.channelCount, original.channelCount)
        XCTAssertEqual(rebound.addedAt, original.addedAt)
    }

    func testKnownStableIDRotationQueuesMigrationAndAuditSynchronously() {
        let previous = "old-\(UUID().uuidString)"
        let updated = "new-\(UUID().uuidString)"
        let configurationID = UUID()
        let defaults = UserDefaults.standard

        let pendingKey = "shelv_pending_download_scope_migration_\(updated)"
        let auditKey = "shelv_download_identity_audit_\(updated)"
        let scopeKey = "shelv_download_scope_server_id_\(configurationID.uuidString)"
        let oldKeepOfflineKey = "shelv_keep_library_offline_\(previous)"
        let newKeepOfflineKey = "shelv_keep_library_offline_\(updated)"

        defaults.set(true, forKey: oldKeepOfflineKey)
        defer {
            for key in [
                pendingKey,
                auditKey,
                scopeKey,
                oldKeepOfflineKey,
                newKeepOfflineKey,
            ] {
                defaults.removeObject(forKey: key)
            }
        }

        XCTAssertTrue(
            DownloadIdentityRepairService.prepareKnownServerScopeMigration(
                from: previous,
                to: updated,
                configurationID: configurationID
            )
        )

        XCTAssertEqual(defaults.string(forKey: pendingKey), previous)
        XCTAssertTrue(defaults.bool(forKey: auditKey))
        XCTAssertEqual(defaults.string(forKey: scopeKey), updated)
        XCTAssertNil(defaults.object(forKey: oldKeepOfflineKey))
        XCTAssertTrue(defaults.bool(forKey: newKeepOfflineKey))
    }

    private func makeRecord(
        songId: String,
        albumId: String = "old-album",
        title: String = "First",
        track: Int? = 1,
        disc: Int? = 1,
        duration: Int? = 180
    ) -> DownloadRecord {
        DownloadRecord(
            songId: songId,
            serverId: "old-server",
            albumId: albumId,
            artistId: "old-artist",
            title: title,
            albumTitle: "Old Album",
            artistName: "Old Artist",
            track: track,
            disc: disc,
            duration: duration,
            year: 2020,
            genre: "Rock",
            playCount: 3,
            explicitStatus: nil,
            bytes: 123_456_789,
            coverArtId: "old-cover",
            artistCoverArtId: "old-artist-cover",
            albumArtistName: "Old Artist",
            albumCoverArtId: "old-album-cover",
            isFavorite: false,
            filePath: "/downloads/old-server/song.flac",
            fileExtension: "flac",
            contentType: "audio/flac",
            bitRate: 1_411,
            bitDepth: 24,
            samplingRate: 96_000,
            channelCount: 2,
            bpm: 100,
            replayGainTrackGain: -1.0,
            replayGainAlbumGain: -2.0,
            addedAt: 1_700_000_000
        )
    }
}
