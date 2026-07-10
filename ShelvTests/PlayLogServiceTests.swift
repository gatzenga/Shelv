import XCTest

final class PlayLogServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelvPlayLogServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        PlayLogService.testDatabaseURL = tempDir.appendingPathComponent("recap.db")
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

    func testDeadSongCleanupPromotesValidSongsWithinOneStabilization() async throws {
        let service = try await makeService()
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let end = Date(timeIntervalSince1970: 1_750_001_000)

        for offset in [10.0, 20.0, 30.0] {
            await service.insertLegacyPlayForTesting(
                songId: "dead-a",
                serverId: "server-a",
                playedAt: start.timeIntervalSince1970 + offset,
                songDuration: 180
            )
        }
        for offset in [40.0, 50.0] {
            await service.insertLegacyPlayForTesting(
                songId: "dead-b",
                serverId: "server-a",
                playedAt: start.timeIntervalSince1970 + offset,
                songDuration: 180
            )
        }
        await service.insertLegacyPlayForTesting(
            songId: "valid",
            serverId: "server-a",
            playedAt: start.timeIntervalSince1970 + 60,
            songDuration: 180
        )

        let deadSongIds = Set(["dead-a", "dead-b"])
        var cleanupCalls: [[String]] = []
        let finalIds: [String] = try await RecapSyncLogic.stabilized(
            scan: {
                let ids = await service.topSongs(
                    serverId: "server-a",
                    from: start,
                    to: end,
                    limit: 1
                ).map(\.songId)
                return (ids, Set(ids.filter { deadSongIds.contains($0) }))
            },
            removeDeadSongIds: { ids in
                cleanupCalls.append(ids)
                return await service.deletePlays(forSongIds: ids, serverId: "server-a")
            }
        )

        let remainingSongIds = await service.allPlayLogs(serverId: "server-a").map(\.songId)
        XCTAssertEqual(finalIds, ["valid"])
        XCTAssertEqual(cleanupCalls, [["dead-a"], ["dead-b"]])
        XCTAssertEqual(remainingSongIds, ["valid"])

        let secondPassIds: [String] = try await RecapSyncLogic.stabilized(
            scan: {
                let ids = await service.topSongs(
                    serverId: "server-a",
                    from: start,
                    to: end,
                    limit: 1
                ).map(\.songId)
                return (ids, Set(ids.filter { deadSongIds.contains($0) }))
            },
            removeDeadSongIds: { ids in
                cleanupCalls.append(ids)
                return await service.deletePlays(forSongIds: ids, serverId: "server-a")
            }
        )

        XCTAssertEqual(secondPassIds, ["valid"])
        XCTAssertEqual(cleanupCalls, [["dead-a"], ["dead-b"]])
    }

    func testKeepOnlyRegistryEntryForSamePeriodKeepsCanonicalRecordOnlyForMatchingBucket() async throws {
        let service = try await makeService()
        let monthStart = Date(timeIntervalSince1970: 1_746_144_000).timeIntervalSince1970

        await service.registerPlaylist(registryRecord("local-a", periodStart: monthStart))
        await service.registerPlaylist(registryRecord("local-b", periodStart: monthStart, ckRecordName: "ck-local-b"))
        await service.registerPlaylist(registryRecord("test-a", periodStart: monthStart, ckRecordName: "ck-test", isTest: true))
        await service.registerPlaylist(registryRecord("other-month", periodStart: monthStart + 31 * 86_400, ckRecordName: "ck-other"))
        await service.registerPlaylist(registryRecord("other-server", serverId: "server-b", periodStart: monthStart, ckRecordName: "ck-server-b"))

        let canonical = registryRecord("cloud-a", periodStart: monthStart, ckRecordName: "ck-cloud-a")
        let removed = await service.keepOnlyRegistryEntryForSamePeriod(canonical)

        XCTAssertEqual(Set(removed), ["local-a", "local-b"])

        let serverAIds = Set(await service.allRegistryEntries(serverId: "server-a").map(\.playlistId))
        XCTAssertEqual(serverAIds, ["cloud-a", "test-a", "other-month"])

        let canonicalEntry = await service.registryEntry(
            serverId: "server-a",
            periodType: "month",
            periodStart: monthStart,
            isTest: false
        )
        XCTAssertEqual(canonicalEntry?.playlistId, "cloud-a")
        XCTAssertEqual(canonicalEntry?.ckRecordName, "ck-cloud-a")

        let testEntry = await service.registryEntry(playlistId: "test-a")
        XCTAssertEqual(testEntry?.ckRecordName, "ck-test")

        let otherServerEntry = await service.registryEntry(playlistId: "other-server")
        XCTAssertEqual(otherServerEntry?.serverId, "server-b")
    }

    func testRecapMarkerReuploadResetAndBulkDeleteStayScoped() async throws {
        let service = try await makeService()
        let monthStart = Date(timeIntervalSince1970: 1_746_144_000).timeIntervalSince1970

        await service.registerPlaylist(registryRecord("server-a-one", periodStart: monthStart, ckRecordName: "ck-a-one"))
        await service.registerPlaylist(registryRecord("server-a-two", periodStart: monthStart + 31 * 86_400, ckRecordName: "ck-a-two"))
        await service.registerPlaylist(registryRecord("server-b-one", serverId: "server-b", periodStart: monthStart, ckRecordName: "ck-b-one"))

        await service.markRecapMarkersUnsyncedForReUpload(serverId: "server-a")

        let serverAOne = await service.registryEntry(playlistId: "server-a-one")
        let serverATwo = await service.registryEntry(playlistId: "server-a-two")
        let serverBOne = await service.registryEntry(playlistId: "server-b-one")

        XCTAssertNil(serverAOne?.ckRecordName)
        XCTAssertNil(serverATwo?.ckRecordName)
        XCTAssertEqual(serverBOne?.ckRecordName, "ck-b-one")

        await service.deleteRegistryEntries(playlistIds: ["server-a-two", "server-b-one", "missing"])

        let remainingServerAOne = await service.registryEntry(playlistId: "server-a-one")
        let removedServerATwo = await service.registryEntry(playlistId: "server-a-two")
        let removedServerBOne = await service.registryEntry(playlistId: "server-b-one")

        XCTAssertNotNil(remainingServerAOne)
        XCTAssertNil(removedServerATwo)
        XCTAssertNil(removedServerBOne)
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

    func testRecapImportRewriteDropsForeignOutboxAndRestoresLocalPendingEvents() async throws {
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

    private func registryRecord(
        _ playlistId: String,
        serverId: String = "server-a",
        periodStart: Double,
        ckRecordName: String? = nil,
        isTest: Bool = false
    ) -> RecapRegistryRecord {
        RecapRegistryRecord(
            playlistId: playlistId,
            serverId: serverId,
            periodType: "month",
            periodStart: periodStart,
            periodEnd: periodStart + 31 * 86_400,
            ckRecordName: ckRecordName,
            isTest: isTest
        )
    }
}
