import XCTest

final class PlayLogServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelvPlayLogServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        PlayLogService.testDatabaseURL = tempDir.appendingPathComponent("playlog.db")
    }

    override func tearDown() async throws {
        await PlayLogService.shared.shutdown()
        PlayLogService.testDatabaseURL = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    func testAssignMissingCloudIdentifiersBackfillsLegacyRowsAndKeepsServerScope() async throws {
        let service = try await makeService()
        let now = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970

        await service.insertLegacyPlayForTesting(songId: "legacy-a1", serverId: "server-a", playedAt: now, songDuration: 180)
        await service.insertLegacyPlayForTesting(songId: "legacy-a2", serverId: "server-a", playedAt: now + 1, songDuration: 181)
        await service.insertLegacyPlayForTesting(songId: "legacy-b1", serverId: "server-b", playedAt: now + 2, songDuration: 182)
        let modernUUID = await service.log(songId: "modern-a1", serverId: "server-a", songDuration: 200)
        let pendingBeforeBackfill = await service.pendingUploadCount()

        XCTAssertNotNil(modernUUID)
        XCTAssertEqual(pendingBeforeBackfill, 1)

        let assignedForServerA = await service.assignMissingCloudIdentifiers(serverId: "server-a")
        let pendingAfterServerBackfill = await service.pendingUploadCount()

        XCTAssertEqual(assignedForServerA, 2)
        XCTAssertEqual(pendingAfterServerBackfill, 3)

        let serverALogs = await service.allPlayLogs(serverId: "server-a")
        XCTAssertEqual(serverALogs.count, 3)
        XCTAssertTrue(serverALogs.allSatisfy { $0.uuid != nil })
        XCTAssertTrue(serverALogs.compactMap(\.uuid).allSatisfy { $0 == $0.lowercased() })

        let serverBLogsBeforeGlobalBackfill = await service.allPlayLogs(serverId: "server-b")
        XCTAssertEqual(serverBLogsBeforeGlobalBackfill.count, 1)
        XCTAssertNil(serverBLogsBeforeGlobalBackfill.first?.uuid)

        let assignedGlobally = await service.assignMissingCloudIdentifiers()
        let pendingAfterGlobalBackfill = await service.pendingUploadCount()

        XCTAssertEqual(assignedGlobally, 1)
        XCTAssertEqual(pendingAfterGlobalBackfill, 4)
    }

    func testInsertIfNotExistsOnlyReportsActualLocalChanges() async throws {
        let service = try await makeService()
        let now = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970

        let firstInsert = await service.insertIfNotExists(
            uuid: "remote-play-1",
            songId: "song-1",
            serverId: "server-a",
            playedAt: now,
            songDuration: 200
        )
        let duplicateInsert = await service.insertIfNotExists(
            uuid: "remote-play-1",
            songId: "song-1",
            serverId: "server-a",
            playedAt: now,
            songDuration: 200
        )
        let serverCorrection = await service.insertIfNotExists(
            uuid: "remote-play-1",
            songId: "song-1",
            serverId: "server-b",
            playedAt: now,
            songDuration: 200
        )
        let pendingUploads = await service.pendingUploadCount()
        let serverALogs = await service.allPlayLogs(serverId: "server-a")
        let serverBLogs = await service.allPlayLogs(serverId: "server-b")

        XCTAssertTrue(firstInsert)
        XCTAssertFalse(duplicateInsert)
        XCTAssertTrue(serverCorrection)
        XCTAssertEqual(pendingUploads, 0)
        XCTAssertEqual(serverALogs.count, 0)
        XCTAssertEqual(serverBLogs.count, 1)
    }

    /// Regressionstest für einen echten Bug: ein zweites Gerät (z.B. Mac) hat die Zeile schon
    /// über iCloud, bevor Metadaten existierten. Holt ein anderes Gerät die Metadaten nach und
    /// re-uploaded dieselbe UUID, darf das zweite Gerät sie beim nächsten Download nicht verwerfen.
    func testInsertIfNotExistsMergesMetadataIntoAnAlreadyKnownRowWithoutErasingExistingValues() async throws {
        let service = try await makeService()
        let now = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970

        let firstInsert = await service.insertIfNotExists(
            uuid: "remote-play-1", songId: "song-1", serverId: "server-a",
            playedAt: now, songDuration: 200
        )
        XCTAssertTrue(firstInsert)

        // Re-Download derselben UUID, jetzt mit Metadaten — muss übernommen werden.
        let metadataArrives = await service.insertIfNotExists(
            uuid: "remote-play-1", songId: "song-1", serverId: "server-a",
            playedAt: now, songDuration: 200,
            songTitle: "Title", artistName: "Artist", albumName: "Album"
        )
        XCTAssertTrue(metadataArrives)

        var logs = await service.allPlayLogs(serverId: "server-a")
        XCTAssertEqual(logs.first?.songTitle, "Title")
        XCTAssertEqual(logs.first?.artistName, "Artist")
        XCTAssertEqual(logs.first?.albumName, "Album")

        // Ein Re-Download ohne Metadaten (z.B. von einem Gerät, das noch nicht reconciled hat)
        // darf die bereits vorhandenen Werte nicht löschen.
        let staleRedownload = await service.insertIfNotExists(
            uuid: "remote-play-1", songId: "song-1", serverId: "server-a",
            playedAt: now, songDuration: 200
        )
        XCTAssertFalse(staleRedownload)

        logs = await service.allPlayLogs(serverId: "server-a")
        XCTAssertEqual(logs.first?.songTitle, "Title")
        XCTAssertEqual(logs.first?.artistName, "Artist")
        XCTAssertEqual(logs.first?.albumName, "Album")
    }

    /// Regressionstest: ein Gerät repariert eine tote ID (repairSongId, gleiche UUID, neue
    /// songId) und re-uploaded. Ein zweites Gerät, das die UUID schon mit der alten ID kennt,
    /// muss die neue ID übernehmen, nicht nur die Metadaten.
    func testInsertIfNotExistsAdoptsARepairedSongIdForAnAlreadyKnownRow() async throws {
        let service = try await makeService()
        let now = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970

        let firstInsert = await service.insertIfNotExists(
            uuid: "remote-play-1", songId: "old-dead-id", serverId: "server-a",
            playedAt: now, songDuration: 200
        )
        XCTAssertTrue(firstInsert)

        let repairArrives = await service.insertIfNotExists(
            uuid: "remote-play-1", songId: "new-repaired-id", serverId: "server-a",
            playedAt: now, songDuration: 200,
            songTitle: "Title", artistName: "Artist", albumName: "Album"
        )
        XCTAssertTrue(repairArrives)

        let logs = await service.allPlayLogs(serverId: "server-a")
        XCTAssertEqual(logs.first?.songId, "new-repaired-id")
        XCTAssertEqual(logs.first?.songTitle, "Title")
    }

    func testTopSongsUsesStableTieBreakers() async throws {
        let service = try await makeService()
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let end = Date(timeIntervalSince1970: 1_750_001_000)

        await service.insertLegacyPlayForTesting(songId: "song-b", serverId: "server-a", playedAt: 1_750_000_010, songDuration: 180)
        await service.insertLegacyPlayForTesting(songId: "song-a", serverId: "server-a", playedAt: 1_750_000_020, songDuration: 180)
        await service.insertLegacyPlayForTesting(songId: "song-c", serverId: "server-a", playedAt: 1_750_000_030, songDuration: 180)
        await service.insertLegacyPlayForTesting(songId: "song-c", serverId: "server-a", playedAt: 1_750_000_040, songDuration: 180)
        await service.insertLegacyPlayForTesting(songId: "song-a", serverId: "server-a", playedAt: 1_750_000_100, songDuration: 180)
        await service.insertLegacyPlayForTesting(songId: "song-b", serverId: "server-a", playedAt: 1_750_000_100, songDuration: 180)
        await service.insertLegacyPlayForTesting(songId: "song-d", serverId: "server-a", playedAt: 1_750_000_200, songDuration: 180)

        let topSongs = await service.topSongs(serverId: "server-a", from: start, to: end, limit: 4)

        XCTAssertEqual(topSongs.map(\.songId), ["song-a", "song-b", "song-c", "song-d"])
        XCTAssertEqual(topSongs.map(\.count), [2, 2, 2, 1])
    }

    func testDistinctSongEntriesFoldsRowsAndPicksUpAnyNonNilMetadata() async throws {
        let service = try await makeService()
        let now = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970

        await service.insertLegacyPlayForTesting(
            songId: "song-1", serverId: "server-a", playedAt: now, songDuration: 180
        )
        await service.insertLegacyPlayForTesting(
            songId: "song-1", serverId: "server-a", playedAt: now + 1, songDuration: 180,
            title: "Title", artist: "Artist", album: "Album"
        )
        await service.insertLegacyPlayForTesting(
            songId: "song-2", serverId: "server-a", playedAt: now, songDuration: 180
        )

        let entries = await service.distinctSongEntries(serverId: "server-a")
            .sorted { $0.songId < $1.songId }

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0], PlayLogSongEntry(songId: "song-1", title: "Title", artist: "Artist", album: "Album"))
        XCTAssertEqual(entries[1], PlayLogSongEntry(songId: "song-2", title: nil, artist: nil, album: nil))
    }

    func testUpdateMetadataOverwritesAllRowsSharingThatSongId() async throws {
        let service = try await makeService()
        let now = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970

        await service.insertLegacyPlayForTesting(
            songId: "song-1", serverId: "server-a", playedAt: now, songDuration: 180,
            title: "Old", artist: "Old Artist", album: "Old Album"
        )
        await service.insertLegacyPlayForTesting(
            songId: "song-1", serverId: "server-a", playedAt: now + 1, songDuration: 180
        )

        await service.updateMetadata(serverId: "server-a", songId: "song-1", title: "New", artist: "New Artist", album: nil)

        let logs = await service.allPlayLogs(serverId: "server-a")
        XCTAssertEqual(logs.count, 2)
        XCTAssertTrue(logs.allSatisfy { $0.songTitle == "New" && $0.artistName == "New Artist" && $0.albumName == nil })
    }

    func testRepairSongIdRewritesIdAndMetadataAndMarksRowsForResync() async throws {
        let service = try await makeService()

        let maybeUuid = await service.log(songId: "old-id", serverId: "server-a", songDuration: 180)
        let uuid = try XCTUnwrap(maybeUuid)
        await service.markSynced(uuids: [uuid])

        await service.repairSongId(
            serverId: "server-a", oldSongId: "old-id", newSongId: "new-id",
            title: "Title", artist: "Artist", album: "Album"
        )

        let logs = await service.allPlayLogs(serverId: "server-a")
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.songId, "new-id")
        XCTAssertEqual(logs.first?.songTitle, "Title")
        XCTAssertEqual(logs.first?.artistName, "Artist")
        XCTAssertEqual(logs.first?.albumName, "Album")
        // syncedAt wird zurückgesetzt, damit die reparierte Zeile erneut nach iCloud hochgeladen wird.
        XCTAssertNil(logs.first?.syncedAt)
    }

    func testRecordPlayAndQueueScrobblePersistsBothAtomically() async throws {
        let service = try await makeService()
        let playedAt = 1_750_000_123.5

        let uuid = await service.recordPlayAndQueueScrobble(
            songId: "offline-song",
            serverId: "server-a",
            serverConfigId: "11111111-1111-1111-1111-111111111111",
            playedAt: playedAt,
            songDuration: 240
        )

        let logs = await service.allPlayLogs(serverId: "server-a")
        let pending = await service.pendingScrobbles(limit: 10)
        XCTAssertNotNil(uuid)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.uuid, uuid)
        XCTAssertEqual(logs.first?.playedAt, playedAt)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.songId, "offline-song")
        XCTAssertEqual(pending.first?.serverConfigId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(pending.first?.playedAt, playedAt)
    }

    func testPendingScrobbleSurvivesDatabaseRestartUntilAcknowledged() async throws {
        let service = try await makeService()
        _ = await service.recordPlayAndQueueScrobble(
            songId: "restart-song",
            serverId: "server-a",
            serverConfigId: "22222222-2222-2222-2222-222222222222",
            playedAt: 1_750_000_321,
            songDuration: 180
        )

        await service.shutdown()
        await service.setup()

        let restored = await service.pendingScrobbles(afterId: nil, limit: 10)
        XCTAssertEqual(restored.map(\.songId), ["restart-song"])
        if let id = restored.first?.id {
            await service.markScrobbleDone(id: id)
        }
        let remaining = await service.pendingScrobbles(limit: 10)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testImportRewriteDropsForeignOutboxAndRestoresLocalPendingEvents() async throws {
        let service = try await makeService()
        _ = await service.addPendingScrobble(
            songId: "local-offline-song",
            serverId: "local-server",
            serverConfigId: "33333333-3333-3333-3333-333333333333",
            playedAt: 1_750_000_456
        )
        let localPending = await service.allPendingScrobbles()

        await service.rewriteAllServerIds(to: "import-target")
        let importedOutboxWasCleared = await service.allPendingScrobbles().isEmpty
        let didRestore = await service.restorePendingScrobbles(localPending)
        XCTAssertTrue(importedOutboxWasCleared)
        XCTAssertTrue(didRestore)

        let restored = await service.allPendingScrobbles()
        XCTAssertEqual(restored.map(\.songId), ["local-offline-song"])
        XCTAssertEqual(restored.first?.serverId, "local-server")
        XCTAssertEqual(
            restored.first?.serverConfigId,
            "33333333-3333-3333-3333-333333333333"
        )
    }

    private func makeService() async throws -> PlayLogService {
        XCTAssertNotNil(PlayLogService.testDatabaseURL)
        await PlayLogService.shared.shutdown()
        await PlayLogService.shared.setup()
        return PlayLogService.shared
    }

}
