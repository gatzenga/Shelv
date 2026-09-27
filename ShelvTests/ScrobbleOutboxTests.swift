import GRDB
import XCTest

final class ScrobbleOutboxTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelvScrobbleOutboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ScrobbleOutbox.testDatabaseURL = tempDir.appendingPathComponent("outbox.db")
        ScrobbleOutbox.testLegacyDatabaseURL = tempDir.appendingPathComponent("legacy/playlog.db")
    }

    override func tearDown() async throws {
        await ScrobbleOutbox.shared.shutdown()
        ScrobbleOutbox.testDatabaseURL = nil
        ScrobbleOutbox.testLegacyDatabaseURL = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    func testQueuedScrobbleSurvivesRestartUntilAcknowledged() async throws {
        let outbox = await makeOutbox()
        let queued = await outbox.enqueue(
            songId: "restart-song",
            serverId: "server-a",
            serverConfigId: "22222222-2222-2222-2222-222222222222",
            playedAt: 1_750_000_321
        )
        XCTAssertTrue(queued)

        await outbox.shutdown()
        await outbox.setup()

        let restored = await outbox.pendingScrobbles(afterId: nil, limit: 10)
        XCTAssertEqual(restored.map(\.songId), ["restart-song"])
        XCTAssertEqual(restored.first?.serverConfigId, "22222222-2222-2222-2222-222222222222")
        if let id = restored.first?.id {
            await outbox.markScrobbleDone(id: id)
        }
        let remaining = await outbox.pendingScrobbleCount()
        XCTAssertEqual(remaining, 0)
    }

    func testRetriesAndServerCleanupOnlyTouchMatchingRows() async throws {
        let outbox = await makeOutbox()
        await outbox.enqueue(songId: "a", serverId: "s1", serverConfigId: "config-1", playedAt: 1)
        await outbox.enqueue(songId: "b", serverId: "s2", serverConfigId: "config-2", playedAt: 2)

        let first = await outbox.pendingScrobbles(afterId: nil, limit: 1)
        let firstId = try XCTUnwrap(first.first?.id)
        await outbox.incrementScrobbleRetry(id: firstId)
        let afterFirst = await outbox.pendingScrobbles(afterId: firstId, limit: 10)
        XCTAssertEqual(afterFirst.map(\.songId), ["b"])

        await outbox.removeScrobbles(serverConfigId: "config-2")
        let remaining = await outbox.pendingScrobbles(afterId: nil, limit: 10)
        XCTAssertEqual(remaining.map(\.songId), ["a"])
        XCTAssertEqual(remaining.first?.retries, 1)
    }

    func testMigrateServerIdRewritesPendingRows() async throws {
        let outbox = await makeOutbox()
        await outbox.enqueue(songId: "a", serverId: "old-id", serverConfigId: nil, playedAt: 1)
        await outbox.migrateServerId(from: "old-id", to: "new-id")
        let rows = await outbox.pendingScrobbles(afterId: nil, limit: 10)
        XCTAssertEqual(rows.map(\.serverId), ["new-id"])
    }

    func testSetupCarriesPendingRowsFromLegacyDatabaseAndDeletesIt() async throws {
        let legacyURL = try XCTUnwrap(ScrobbleOutbox.testLegacyDatabaseURL)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = try DatabaseQueue(path: legacyURL.path)
        try await legacy.write { db in
            try db.execute(sql: """
                CREATE TABLE play_log (id INTEGER PRIMARY KEY, songId TEXT NOT NULL);
                CREATE TABLE scrobble_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    songId TEXT NOT NULL,
                    serverId TEXT NOT NULL,
                    playedAt DOUBLE NOT NULL,
                    retries INTEGER NOT NULL DEFAULT 0,
                    serverConfigId TEXT
                );
                INSERT INTO play_log (songId) VALUES ('history-only');
                INSERT INTO scrobble_queue (songId, serverId, playedAt, retries, serverConfigId)
                VALUES ('pending-1', 'server-a', 10, 2, 'config-a'),
                       ('pending-2', 'server-a', 20, 0, NULL);
                """)
        }
        try legacy.close()

        let outbox = await makeOutbox()
        let rows = await outbox.pendingScrobbles(afterId: nil, limit: 10)
        XCTAssertEqual(rows.map(\.songId), ["pending-1", "pending-2"])
        XCTAssertEqual(rows.first?.retries, 2)
        XCTAssertEqual(rows.first?.serverConfigId, "config-a")
        XCTAssertNil(rows.last?.serverConfigId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    private func makeOutbox() async -> ScrobbleOutbox {
        await ScrobbleOutbox.shared.shutdown()
        await ScrobbleOutbox.shared.setup()
        return ScrobbleOutbox.shared
    }
}
