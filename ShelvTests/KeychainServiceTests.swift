import Dispatch
import Foundation
import LocalAuthentication
import Security
import XCTest

private nonisolated final class KeychainAsyncTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        guard !isSignaled else {
            lock.unlock()
            return
        }
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSignaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private struct KeychainExecutorObservation: Sendable {
    let lookup: KeychainCredentialLookup
    let ranOnMainThread: Bool
}

private struct KeychainExecutorProbeSnapshot: Sendable {
    let events: [String]
    let activeTransactions: Int
    let maximumConcurrentTransactions: Int
}

private nonisolated final class KeychainExecutorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseFirstSemaphore = DispatchSemaphore(value: 0)
    private let firstEntered = KeychainAsyncTestSignal()
    private var events: [String] = []
    private var activeTransactions = 0
    private var maximumConcurrentTransactions = 0

    func waitUntilFirstEntered() async {
        await firstEntered.wait()
    }

    func releaseFirst() {
        DispatchQueue.global(qos: .userInitiated).async { [releaseFirstSemaphore] in
            releaseFirstSemaphore.signal()
        }
    }

    func runTransaction(
        label: String,
        blocksUntilReleased: Bool
    ) -> KeychainSaveResult {
        lock.lock()
        activeTransactions += 1
        maximumConcurrentTransactions = max(
            maximumConcurrentTransactions,
            activeTransactions
        )
        events.append("\(label).begin")
        lock.unlock()

        defer {
            lock.lock()
            events.append("\(label).end")
            activeTransactions -= 1
            lock.unlock()
        }

        if blocksUntilReleased {
            firstEntered.signal()
            releaseFirstSemaphore.wait()
        }

        let operations = KeychainServiceOperations(
            copyMatching: { [self] _ in
                record("\(label).copy")
                return (errSecItemNotFound, nil)
            },
            update: { [self] _, _ in
                record("\(label).update")
                return errSecSuccess
            },
            add: { [self] _ in
                record("\(label).add")
                return errSecSuccess
            },
            delete: { [self] _ in
                record("\(label).delete")
                return errSecSuccess
            }
        )
        return KeychainService.save(
            password: "\(label)-secret",
            for: UUID(),
            operations: operations
        )
    }

    func snapshot() -> KeychainExecutorProbeSnapshot {
        lock.lock()
        let value = KeychainExecutorProbeSnapshot(
            events: events,
            activeTransactions: activeTransactions,
            maximumConcurrentTransactions: maximumConcurrentTransactions
        )
        lock.unlock()
        return value
    }

    private func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

final class KeychainServiceTests: XCTestCase {
    private final class ScriptedOperations {
        var copyResponses: [(OSStatus, Any?)] = []
        var updateStatuses: [OSStatus] = []
        var addStatuses: [OSStatus] = []
        var deleteStatuses: [OSStatus] = []

        private(set) var copyQueries: [[CFString: Any]] = []
        private(set) var updateCalls: [([CFString: Any], [CFString: Any])] = []
        private(set) var addQueries: [[CFString: Any]] = []
        private(set) var deleteQueries: [[CFString: Any]] = []

        var operations: KeychainServiceOperations {
            KeychainServiceOperations(
                copyMatching: { [self] query in
                    copyQueries.append(query)
                    guard !copyResponses.isEmpty else {
                        return (errSecParam, nil)
                    }
                    return copyResponses.removeFirst()
                },
                update: { [self] query, attributes in
                    updateCalls.append((query, attributes))
                    guard !updateStatuses.isEmpty else { return errSecParam }
                    return updateStatuses.removeFirst()
                },
                add: { [self] query in
                    addQueries.append(query)
                    guard !addStatuses.isEmpty else { return errSecParam }
                    return addStatuses.removeFirst()
                },
                delete: { [self] query in
                    deleteQueries.append(query)
                    guard !deleteStatuses.isEmpty else { return errSecParam }
                    return deleteStatuses.removeFirst()
                }
            )
        }
    }

    private let serverID = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    private let expectedAccount =
        "shelv_server_AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    @MainActor
    func testLiveExecutorRunsTheLookupTransactionOffMainThread() async {
        let observation = await KeychainService.runSerializedForTesting {
            let operations = KeychainServiceOperations(
                copyMatching: { _ in
                    (errSecSuccess, Data("worker-secret".utf8))
                },
                update: { _, _ in errSecParam },
                add: { _ in errSecParam },
                delete: { _ in errSecParam }
            )
            return KeychainExecutorObservation(
                lookup: KeychainService.lookup(
                    for: UUID(),
                    operations: operations
                ),
                ranOnMainThread: Thread.isMainThread
            )
        }

        XCTAssertEqual(observation.lookup, .available("worker-secret"))
        XCTAssertFalse(observation.ranOnMainThread)
    }

    @MainActor
    func testLiveExecutorSerializesWholeTransactionsWithoutInterleaving() async {
        let probe = KeychainExecutorProbe()
        let first = Task {
            await KeychainService.runSerializedForTesting {
                probe.runTransaction(label: "A", blocksUntilReleased: true)
            }
        }
        await probe.waitUntilFirstEntered()

        let secondEnqueued = KeychainAsyncTestSignal()
        let second = Task {
            await KeychainService.runSerializedForTesting(
                didEnqueue: { secondEnqueued.signal() },
                operation: {
                    probe.runTransaction(label: "B", blocksUntilReleased: false)
                }
            )
        }
        await secondEnqueued.wait()

        let blocked = probe.snapshot()
        XCTAssertEqual(blocked.events, ["A.begin"])
        XCTAssertEqual(blocked.activeTransactions, 1)
        XCTAssertEqual(blocked.maximumConcurrentTransactions, 1)

        probe.releaseFirst()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult.succeeded)
        XCTAssertTrue(secondResult.succeeded)

        let completed = probe.snapshot()
        XCTAssertEqual(completed.activeTransactions, 0)
        XCTAssertEqual(completed.maximumConcurrentTransactions, 1)
        let firstB = completed.events.firstIndex { $0.hasPrefix("B.") }
        let lastA = completed.events.lastIndex { $0.hasPrefix("A.") }
        XCTAssertNotNil(firstB)
        XCTAssertNotNil(lastA)
        if let firstB, let lastA {
            XCTAssertLessThan(lastA, firstB)
        }
    }

    func testSaveUpdatesInPlaceWithoutDeleteOrAdd() {
        let script = ScriptedOperations()
        script.updateStatuses = [errSecSuccess]
        #if os(macOS)
        script.copyResponses = [(errSecItemNotFound, nil)]
        #endif

        let result = KeychainService.save(
            password: "new-secret",
            for: serverID,
            operations: script.operations
        )

        XCTAssertEqual(result, .success(legacyCleanup: .notNeeded))
        XCTAssertEqual(script.updateCalls.count, 1)
        XCTAssertTrue(script.addQueries.isEmpty)
        XCTAssertTrue(script.deleteQueries.isEmpty)
        let (query, attributes) = script.updateCalls[0]
        assertPrimaryQuery(query)
        XCTAssertEqual(attributes.count, 1)
        XCTAssertEqual(attributes[kSecValueData] as? Data, Data("new-secret".utf8))
        XCTAssertNil(attributes[kSecAttrAccessible])
        XCTAssertNil(attributes[kSecUseDataProtectionKeychain])
    }

    func testSaveAddsAfterMissingWithAfterFirstUnlockAccessibility() {
        let script = ScriptedOperations()
        script.updateStatuses = [errSecItemNotFound]
        script.addStatuses = [errSecSuccess]
        #if os(macOS)
        script.copyResponses = [(errSecItemNotFound, nil)]
        #endif

        let result = KeychainService.save(
            password: "new-secret",
            for: serverID,
            operations: script.operations
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(script.addQueries.count, 1)
        let add = script.addQueries[0]
        XCTAssertEqual(add[kSecClass] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(add[kSecAttrAccount] as? String, expectedAccount)
        XCTAssertEqual(add[kSecValueData] as? Data, Data("new-secret".utf8))
        XCTAssertEqual(
            add[kSecAttrAccessible] as! CFString,
            kSecAttrAccessibleAfterFirstUnlock
        )
        XCTAssertEqual(add[kSecUseDataProtectionKeychain] as? Bool, true)
        XCTAssertNil(add[kSecAttrService])
        XCTAssertNil(add[kSecAttrAccessGroup])
    }

    func testSaveRetriesOneUpdateAfterConcurrentDuplicateAdd() {
        let script = ScriptedOperations()
        script.updateStatuses = [errSecItemNotFound, errSecSuccess]
        script.addStatuses = [errSecDuplicateItem]
        #if os(macOS)
        script.copyResponses = [(errSecItemNotFound, nil)]
        #endif

        let result = KeychainService.save(
            password: "new-secret",
            for: serverID,
            operations: script.operations
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(script.updateCalls.count, 2)
        XCTAssertEqual(script.addQueries.count, 1)
        XCTAssertTrue(script.deleteQueries.isEmpty)
    }

    func testSaveFailureNeverDeletesTheExistingCredential() {
        let script = ScriptedOperations()
        script.updateStatuses = [errSecInteractionNotAllowed]

        let result = KeychainService.save(
            password: "must-not-be-lost",
            for: serverID,
            operations: script.operations
        )

        XCTAssertEqual(result, .failure(errSecInteractionNotAllowed))
        XCTAssertTrue(script.addQueries.isEmpty)
        XCTAssertTrue(script.deleteQueries.isEmpty)
        XCTAssertTrue(script.copyQueries.isEmpty)
    }

    func testPrimaryProtectionAndFailuresNeverFallBackToLegacy() {
        var statuses: [OSStatus] = [
            errSecInteractionNotAllowed,
            errSecMissingEntitlement,
            errSecParam,
        ]
        #if os(iOS) || os(tvOS)
        statuses.append(errSecNotAvailable)
        #endif

        for status in statuses {
            let script = ScriptedOperations()
            script.copyResponses = [(status, nil)]

            let result = KeychainService.lookup(
                for: serverID,
                operations: script.operations
            )

            let expectsProtectedData: Bool
            #if os(iOS) || os(tvOS)
            expectsProtectedData = status == errSecInteractionNotAllowed
                || status == errSecNotAvailable
            #else
            expectsProtectedData = status == errSecInteractionNotAllowed
            #endif
            if expectsProtectedData {
                XCTAssertEqual(result, .protectedDataUnavailable)
            } else {
                XCTAssertEqual(result, .failed(status))
            }
            XCTAssertEqual(script.copyQueries.count, 1)
            XCTAssertTrue(script.addQueries.isEmpty)
            XCTAssertTrue(script.deleteQueries.isEmpty)
        }

        let undecodable = ScriptedOperations()
        undecodable.copyResponses = [(errSecSuccess, Data([0xFF]))]
        XCTAssertEqual(
            KeychainService.lookup(
                for: serverID,
                operations: undecodable.operations
            ),
            .failed(errSecDecode)
        )
        XCTAssertEqual(undecodable.copyQueries.count, 1)
    }

    func testMissingCredentialRemainsDistinctFromSecurityFailure() {
        let script = ScriptedOperations()
        #if os(macOS)
        script.copyResponses = [
            (errSecItemNotFound, nil),
            (errSecItemNotFound, nil),
        ]
        #else
        script.copyResponses = [(errSecItemNotFound, nil)]
        #endif

        XCTAssertEqual(
            KeychainService.lookup(for: serverID, operations: script.operations),
            .missing
        )
        XCTAssertTrue(script.addQueries.isEmpty)
        XCTAssertTrue(script.deleteQueries.isEmpty)
    }

    func testPrimaryLookupUsesDataProtectionAndSuppressesInteraction() {
        let script = ScriptedOperations()
        script.copyResponses = [(errSecSuccess, Data("secret".utf8))]

        XCTAssertEqual(
            KeychainService.lookup(for: serverID, operations: script.operations),
            .available("secret")
        )
        XCTAssertEqual(script.copyQueries.count, 1)
        let query = script.copyQueries[0]
        assertPrimaryQuery(query)
        XCTAssertEqual(query[kSecReturnData] as? Bool, true)
        XCTAssertNotNil(query[kSecUseAuthenticationContext] as? LAContext)
    }

    func testDeletePreservesPrimaryWhenLegacyCleanupFails() {
        let script = ScriptedOperations()
        #if os(macOS)
        let persistentReference = Data("legacy-delete-reference".utf8)
        script.copyResponses = [
            legacyResult(password: "legacy-secret", reference: persistentReference),
        ]
        script.deleteStatuses = [errSecInteractionNotAllowed]
        #else
        script.deleteStatuses = [errSecInteractionNotAllowed]
        #endif

        let result = KeychainService.delete(
            for: serverID,
            operations: script.operations
        )

        XCTAssertFalse(result.succeeded)
        #if os(macOS)
        XCTAssertNil(result.dataProtectionStatus)
        XCTAssertEqual(result.legacyStatus, errSecInteractionNotAllowed)
        XCTAssertEqual(script.deleteQueries.count, 1)
        XCTAssertEqual(
            (script.deleteQueries[0][kSecMatchItemList] as? [Data])?.first,
            persistentReference
        )
        XCTAssertFalse(script.deleteQueries.contains { query in
            (query[kSecUseDataProtectionKeychain] as? Bool) == true
        })
        #else
        XCTAssertEqual(result.dataProtectionStatus, errSecInteractionNotAllowed)
        XCTAssertNil(result.legacyStatus)
        XCTAssertEqual(script.deleteQueries.count, 1)
        assertPrimaryQuery(script.deleteQueries[0])
        #endif
    }

    #if os(macOS)
    func testDeleteRemovesLegacyBeforePrimaryWhenBothStoresSucceed() {
        let script = ScriptedOperations()
        let persistentReference = Data("legacy-delete-reference".utf8)
        script.copyResponses = [
            legacyResult(password: "legacy-secret", reference: persistentReference),
        ]
        script.deleteStatuses = [errSecSuccess, errSecSuccess]

        let result = KeychainService.delete(
            for: serverID,
            operations: script.operations
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.legacyStatus, errSecSuccess)
        XCTAssertEqual(result.dataProtectionStatus, errSecSuccess)
        XCTAssertEqual(script.deleteQueries.count, 2)
        XCTAssertEqual(
            (script.deleteQueries[0][kSecMatchItemList] as? [Data])?.first,
            persistentReference
        )
        assertPrimaryQuery(script.deleteQueries[1])
    }

    func testLegacyLookupMigratesThenDeletesOnlyTheExactLegacyItem() {
        let script = ScriptedOperations()
        let persistentReference = Data("legacy-reference".utf8)
        script.copyResponses = [
            (errSecItemNotFound, nil),
            legacyResult(password: "legacy-secret", reference: persistentReference),
            (errSecSuccess, Data("legacy-secret".utf8)),
        ]
        script.addStatuses = [errSecSuccess]
        script.deleteStatuses = [errSecSuccess]

        let result = KeychainService.lookup(
            for: serverID,
            operations: script.operations
        )

        XCTAssertEqual(result, .available("legacy-secret"))
        XCTAssertEqual(script.copyQueries.count, 3)
        assertPrimaryQuery(script.copyQueries[0])
        assertLegacyQuery(script.copyQueries[1])
        assertPrimaryQuery(script.copyQueries[2])
        XCTAssertEqual(script.addQueries.count, 1)
        XCTAssertEqual(script.deleteQueries.count, 1)
        XCTAssertEqual(
            (script.deleteQueries[0][kSecMatchItemList] as? [Data])?.first,
            persistentReference
        )
        XCTAssertNil(script.deleteQueries[0][kSecUseDataProtectionKeychain])
        XCTAssertNil(script.deleteQueries[0][kSecMatchSearchList])
        XCTAssertNil(script.deleteQueries[0][kSecUseKeychain])
    }

    func testConcurrentPrimaryInsertWinsOverTheLegacyValue() {
        let script = ScriptedOperations()
        let persistentReference = Data("legacy-reference".utf8)
        script.copyResponses = [
            (errSecItemNotFound, nil),
            legacyResult(password: "old-secret", reference: persistentReference),
            (errSecSuccess, Data("new-secret".utf8)),
        ]
        script.addStatuses = [errSecDuplicateItem]
        script.deleteStatuses = [errSecSuccess]

        let result = KeychainService.lookup(
            for: serverID,
            operations: script.operations
        )

        XCTAssertEqual(result, .available("new-secret"))
        XCTAssertTrue(script.updateCalls.isEmpty)
        XCTAssertEqual(script.deleteQueries.count, 1)
    }

    func testFailedLegacyMigrationKeepsTheUsableLegacyCredential() {
        let script = ScriptedOperations()
        script.copyResponses = [
            (errSecItemNotFound, nil),
            legacyResult(
                password: "legacy-secret",
                reference: Data("legacy-reference".utf8)
            ),
        ]
        script.addStatuses = [errSecMissingEntitlement]

        let result = KeychainService.lookup(
            for: serverID,
            operations: script.operations
        )

        XCTAssertEqual(result, .available("legacy-secret"))
        XCTAssertTrue(script.deleteQueries.isEmpty)
    }

    func testSaveCleansAnExactLegacyItemOnlyAfterPrimarySuccess() {
        let script = ScriptedOperations()
        let persistentReference = Data("legacy-reference".utf8)
        script.updateStatuses = [errSecSuccess]
        script.copyResponses = [
            legacyResult(password: "old-secret", reference: persistentReference),
        ]
        script.deleteStatuses = [errSecSuccess]

        let result = KeychainService.save(
            password: "new-secret",
            for: serverID,
            operations: script.operations
        )

        XCTAssertEqual(result, .success(legacyCleanup: .removed))
        XCTAssertEqual(script.deleteQueries.count, 1)
        XCTAssertEqual(
            (script.deleteQueries[0][kSecMatchItemList] as? [Data])?.first,
            persistentReference
        )
    }

    func testLegacyCleanupFailureDoesNotMisreportAPrimarySaveFailure() {
        let script = ScriptedOperations()
        script.updateStatuses = [errSecSuccess]
        script.copyResponses = [
            legacyResult(
                password: "old-secret",
                reference: Data("legacy-reference".utf8)
            ),
        ]
        script.deleteStatuses = [errSecInteractionNotAllowed]

        XCTAssertEqual(
            KeychainService.save(
                password: "new-secret",
                for: serverID,
                operations: script.operations
            ),
            .success(legacyCleanup: .deferred(errSecInteractionNotAllowed))
        )
    }

    func testLegacySuccessWithoutAFileKeychainItemReferenceIsRejected() {
        let script = ScriptedOperations()
        let values: NSDictionary = [
            kSecValueData: Data("ambiguous-secret".utf8),
            kSecValuePersistentRef: Data("ambiguous-reference".utf8),
        ]
        script.copyResponses = [
            (errSecItemNotFound, nil),
            (errSecSuccess, values),
        ]

        XCTAssertEqual(
            KeychainService.lookup(for: serverID, operations: script.operations),
            .failed(errSecDecode)
        )
        XCTAssertTrue(script.addQueries.isEmpty)
        XCTAssertTrue(script.deleteQueries.isEmpty)
    }

    func testLegacyInteractionFailureIsNotClassifiedAsProtectedData() {
        let script = ScriptedOperations()
        script.copyResponses = [
            (errSecItemNotFound, nil),
            (errSecInteractionNotAllowed, nil),
        ]

        XCTAssertEqual(
            KeychainService.lookup(for: serverID, operations: script.operations),
            .failed(errSecInteractionNotAllowed)
        )
    }

    private func legacyResult(
        password: String,
        reference: Data
    ) -> (OSStatus, Any?) {
        let values: NSDictionary = [
            kSecValueData: Data(password.utf8),
            kSecValuePersistentRef: reference,
            kSecValueRef: "file-keychain-item",
        ]
        return (errSecSuccess, values)
    }

    private func assertLegacyQuery(
        _ query: [CFString: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            query[kSecUseDataProtectionKeychain] as? Bool,
            false,
            file: file,
            line: line
        )
        XCTAssertEqual(query[kSecReturnData] as? Bool, true, file: file, line: line)
        XCTAssertEqual(
            query[kSecReturnPersistentRef] as? Bool,
            true,
            file: file,
            line: line
        )
        XCTAssertEqual(query[kSecReturnRef] as? Bool, true, file: file, line: line)
        XCTAssertNil(query[kSecMatchSearchList], file: file, line: line)
        XCTAssertNil(query[kSecUseKeychain], file: file, line: line)
    }
    #endif

    private func assertPrimaryQuery(
        _ query: [CFString: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            query[kSecClass] as! CFString,
            kSecClassGenericPassword,
            file: file,
            line: line
        )
        XCTAssertEqual(
            query[kSecAttrAccount] as? String,
            expectedAccount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            query[kSecUseDataProtectionKeychain] as? Bool,
            true,
            file: file,
            line: line
        )
        XCTAssertNil(query[kSecAttrService], file: file, line: line)
        XCTAssertNil(query[kSecAttrAccessGroup], file: file, line: line)
    }
}
