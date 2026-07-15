import Dispatch
import Foundation
#if !os(tvOS)
import LocalAuthentication
#endif
import OSLog
import Security

/// `SecItem` may block while the operating system consults a Keychain or its
/// access policy. Every live operation runs away from the main actor, and a
/// single serial executor protects complete read/update/migration transactions
/// from interleaving with each other.
private nonisolated final class KeychainSerialExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "ch.vkugler.Shelv.Keychain",
        qos: .userInitiated
    )

    func run<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result
    ) async -> Result {
        await run(didEnqueue: {}, operation)
    }

    fileprivate func run<Result: Sendable>(
        didEnqueue: @escaping @Sendable () -> Void,
        _ operation: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
            didEnqueue()
        }
    }
}

/// A lossless credential read result. In particular, a missing credential and
/// a temporarily inaccessible Keychain are different states.
nonisolated enum KeychainCredentialLookup: Equatable, Sendable {
    case available(String)
    case missing
    case protectedDataUnavailable
    case failed(OSStatus)
}

nonisolated enum KeychainLegacyCleanupOutcome: Equatable, Sendable {
    case notNeeded
    case removed
    case deferred(OSStatus)
}

nonisolated enum KeychainSaveResult: Equatable, Sendable {
    case success(legacyCleanup: KeychainLegacyCleanupOutcome)
    case failure(OSStatus)

    var succeeded: Bool {
        if case .success = self { return true }
        return false
    }

    var failureStatus: OSStatus? {
        guard case .failure(let status) = self else { return nil }
        return status
    }
}

nonisolated struct KeychainDeletionResult: Equatable, Sendable {
    /// Nil when deletion was deliberately not attempted because legacy
    /// credential cleanup failed first. In that case the primary credential
    /// is preserved so a retained server configuration remains usable.
    let dataProtectionStatus: OSStatus?
    let legacyStatus: OSStatus?

    var succeeded: Bool {
        let primarySucceeded = dataProtectionStatus.map {
            $0 == errSecSuccess || $0 == errSecItemNotFound
        } ?? false
        let legacySucceeded = legacyStatus.map {
            $0 == errSecSuccess || $0 == errSecItemNotFound
        } ?? true
        return primarySucceeded && legacySucceeded
    }
}

/// A narrow seam around the blocking Security framework. Production uses the
/// live implementation; deterministic tests inject scripted status sequences
/// without modifying the developer's Keychain.
nonisolated struct KeychainServiceOperations {
    let copyMatching: ([CFString: Any]) -> (OSStatus, Any?)
    let update: ([CFString: Any], [CFString: Any]) -> OSStatus
    let add: ([CFString: Any]) -> OSStatus
    let delete: ([CFString: Any]) -> OSStatus

    fileprivate static func live() -> Self {
        Self(
            copyMatching: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result)
            },
            update: { query, attributes in
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            },
            add: { query in
                SecItemAdd(query as CFDictionary, nil)
            },
            delete: { query in
                SecItemDelete(query as CFDictionary)
            }
        )
    }
}

nonisolated enum KeychainService {
    private enum CredentialStore: Equatable {
        case dataProtection
        case legacyFileKeychain
    }

    private enum RawCredentialRead {
        case available(String, persistentReference: Data?)
        case missing
        case protectedDataUnavailable(OSStatus)
        case failed(OSStatus)
    }

    private static let logger = Logger(
        subsystem: "ch.vkugler.Shelv",
        category: "CredentialStorage"
    )
    private static let executor = KeychainSerialExecutor()

    #if SHELV_LOGIC_TESTS
    /// Exercises the exact production executor without touching a live
    /// Keychain. `didEnqueue` lets tests prove serialization without sleeps.
    static func runSerializedForTesting<Result: Sendable>(
        didEnqueue: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () -> Result
    ) async -> Result {
        await executor.run(didEnqueue: didEnqueue, operation)
    }
    #endif

    /// Saves a credential without deleting the previous value first. Callers
    /// must await the result before committing the corresponding server config.
    @discardableResult
    static func save(
        password: String,
        for serverID: UUID
    ) async -> KeychainSaveResult {
        await executor.run {
            save(password: password, for: serverID, operations: .live())
        }
    }

    @discardableResult
    static func save(
        password: String,
        for serverID: UUID,
        operations: KeychainServiceOperations
    ) -> KeychainSaveResult {
        let account = accountKey(for: serverID)
        let data = Data(password.utf8)
        let updateStatus = operations.update(
            dataProtectionQuery(account: account),
            [kSecValueData: data]
        )

        let savedStatus: OSStatus
        switch updateStatus {
        case errSecSuccess:
            savedStatus = errSecSuccess
        case errSecItemNotFound:
            let addStatus = operations.add(
                dataProtectionAddQuery(account: account, data: data)
            )
            if addStatus == errSecDuplicateItem {
                // Another process inserted the same logical item between the
                // update and add. Retry one bounded in-place update.
                savedStatus = operations.update(
                    dataProtectionQuery(account: account),
                    [kSecValueData: data]
                )
            } else {
                savedStatus = addStatus
            }
        default:
            savedStatus = updateStatus
        }

        guard savedStatus == errSecSuccess else {
            logger.error(
                "Data Protection Keychain save failed with status \(savedStatus, privacy: .public)"
            )
            return .failure(savedStatus)
        }

        return .success(
            legacyCleanup: cleanupLegacyItem(
                account: account,
                operations: operations
            )
        )
    }

    static func lookup(for serverID: UUID) async -> KeychainCredentialLookup {
        await executor.run {
            lookup(for: serverID, operations: .live())
        }
    }

    static func lookup(
        for serverID: UUID,
        operations: KeychainServiceOperations
    ) -> KeychainCredentialLookup {
        let account = accountKey(for: serverID)
        switch readDataProtectionCredential(
            account: account,
            operations: operations
        ) {
        case .available(let password, _):
            return .available(password)
        case .missing:
            #if os(macOS)
            return migrateLegacyCredentialIfPresent(
                account: account,
                operations: operations
            )
            #else
            return .missing
            #endif
        case .protectedDataUnavailable:
            // A protected/newer primary item must never be masked by a stale
            // legacy macOS credential.
            return .protectedDataUnavailable
        case .failed(let status):
            // Legacy fallback is allowed only after an exact primary miss.
            return .failed(status)
        }
    }

    /// Convenience for callers that do not need the exact failure reason.
    static func load(for serverID: UUID) async -> String? {
        guard case .available(let password) = await lookup(for: serverID) else {
            return nil
        }
        return password
    }

    /// Deletes the exact pre-migration file-Keychain item first on macOS, then
    /// the primary Data Protection item. All statuses remain visible to the
    /// caller, which can avoid removing server configuration after a failure.
    @discardableResult
    static func delete(for serverID: UUID) async -> KeychainDeletionResult {
        await executor.run {
            delete(for: serverID, operations: .live())
        }
    }

    @discardableResult
    static func delete(
        for serverID: UUID,
        operations: KeychainServiceOperations
    ) -> KeychainDeletionResult {
        let account = accountKey(for: serverID)

        #if os(macOS)
        let legacyStatus: OSStatus? = switch readLegacyCredential(
            account: account,
            operations: operations
        ) {
        case .available(_, let persistentReference):
            if let persistentReference {
                deleteLegacyItem(
                    persistentReference: persistentReference,
                    operations: operations
                )
            } else {
                errSecDecode
            }
        case .missing:
            errSecItemNotFound
        case .protectedDataUnavailable(let status), .failed(let status):
            status
        }
        #else
        let legacyStatus: OSStatus? = nil
        #endif

        // On macOS, preserve the modern credential when the legacy item could
        // not be inspected or removed. ServerStore will retain the matching
        // configuration, so deleting the only usable password first would
        // turn a recoverable cleanup error into credential loss.
        let legacySucceeded = legacyStatus.map {
            $0 == errSecSuccess || $0 == errSecItemNotFound
        } ?? true
        let primaryStatus: OSStatus? = legacySucceeded
            ? operations.delete(dataProtectionQuery(account: account))
            : nil

        let result = KeychainDeletionResult(
            dataProtectionStatus: primaryStatus,
            legacyStatus: legacyStatus
        )
        if !result.succeeded {
            logger.error(
                "Keychain delete incomplete; primary=\(primaryStatus ?? errSecSuccess, privacy: .public), legacy=\(legacyStatus ?? errSecSuccess, privacy: .public)"
            )
        }
        return result
    }

    private static func accountKey(for serverID: UUID) -> String {
        "shelv_server_\(serverID.uuidString)"
    }

    private static func dataProtectionQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        #if !os(tvOS)
        query[kSecUseAuthenticationContext] = noninteractiveContext()
        #endif
        return query
    }

    private static func dataProtectionAddQuery(
        account: String,
        data: Data
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    #if os(macOS)
    private static func legacyQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: false,
            kSecUseAuthenticationContext: noninteractiveContext(),
        ]
    }
    #endif

    #if !os(tvOS)
    private static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
    #endif

    private static func readDataProtectionCredential(
        account: String,
        operations: KeychainServiceOperations
    ) -> RawCredentialRead {
        var query = dataProtectionQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let (status, result) = operations.copyMatching(query)
        return decodeRead(
            status: status,
            result: result,
            store: .dataProtection
        )
    }

    #if os(macOS)
    private static func readLegacyCredential(
        account: String,
        operations: KeychainServiceOperations
    ) -> RawCredentialRead {
        var query = legacyQuery(account: account)
        query[kSecReturnData] = true
        query[kSecReturnPersistentRef] = true
        query[kSecReturnRef] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let (status, result) = operations.copyMatching(query)
        return decodeRead(
            status: status,
            result: result,
            store: .legacyFileKeychain
        )
    }
    #endif

    private static func decodeRead(
        status: OSStatus,
        result: Any?,
        store: CredentialStore
    ) -> RawCredentialRead {
        #if os(macOS)
        if store == .legacyFileKeychain,
           status == errSecInteractionNotAllowed {
            // A locked legacy file Keychain or denied ACL is not the iOS-style
            // pre-first-unlock Data Protection state.
            return .failed(status)
        }
        #endif

        if status == errSecItemNotFound {
            return .missing
        }
        if status == errSecInteractionNotAllowed {
            return .protectedDataUnavailable(status)
        }
        #if os(iOS) || os(tvOS)
        if status == errSecNotAvailable {
            return .protectedDataUnavailable(status)
        }
        #endif
        guard status == errSecSuccess else {
            return .failed(status)
        }

        let data: Data?
        let persistentReference: Data?
        if store == .legacyFileKeychain {
            let values = result as? NSDictionary
            guard values?[kSecValueRef] != nil else {
                // A normal item reference proves this result belongs to the
                // legacy file Keychain rather than a shimmed primary item.
                return .failed(errSecDecode)
            }
            data = values?[kSecValueData] as? Data
            persistentReference = values?[kSecValuePersistentRef] as? Data
        } else {
            data = result as? Data
            persistentReference = nil
        }

        guard let data,
              let password = String(data: data, encoding: .utf8)
        else {
            return .failed(errSecDecode)
        }
        return .available(password, persistentReference: persistentReference)
    }

    #if os(macOS)
    private static func migrateLegacyCredentialIfPresent(
        account: String,
        operations: KeychainServiceOperations
    ) -> KeychainCredentialLookup {
        switch readLegacyCredential(account: account, operations: operations) {
        case .available(let legacyPassword, let persistentReference):
            let addStatus = operations.add(
                dataProtectionAddQuery(
                    account: account,
                    data: Data(legacyPassword.utf8)
                )
            )
            guard addStatus == errSecSuccess
                    || addStatus == errSecDuplicateItem
            else {
                // The migration failed, but the old credential remains usable
                // and intact. A later lookup can retry.
                logger.error(
                    "Legacy Keychain migration deferred with status \(addStatus, privacy: .public)"
                )
                return .available(legacyPassword)
            }

            // Never delete the source until the primary item can be read back.
            switch readDataProtectionCredential(
                account: account,
                operations: operations
            ) {
            case .available(let primaryPassword, _):
                if let persistentReference {
                    let cleanupStatus = deleteLegacyItem(
                        persistentReference: persistentReference,
                        operations: operations
                    )
                    if cleanupStatus != errSecSuccess
                        && cleanupStatus != errSecItemNotFound {
                        logger.error(
                            "Legacy Keychain cleanup deferred with status \(cleanupStatus, privacy: .public)"
                        )
                    }
                } else {
                    logger.error(
                        "Legacy Keychain cleanup deferred because no persistent reference was returned"
                    )
                }
                // A concurrent process may have inserted a newer credential.
                // The verified primary value is always authoritative.
                return .available(primaryPassword)
            case .protectedDataUnavailable:
                return .protectedDataUnavailable
            case .failed(let status):
                return .failed(status)
            case .missing:
                return .failed(errSecItemNotFound)
            }
        case .missing:
            return .missing
        case .protectedDataUnavailable:
            return .protectedDataUnavailable
        case .failed(let status):
            return .failed(status)
        }
    }

    private static func cleanupLegacyItem(
        account: String,
        operations: KeychainServiceOperations
    ) -> KeychainLegacyCleanupOutcome {
        switch readLegacyCredential(account: account, operations: operations) {
        case .missing:
            return .notNeeded
        case .available(_, let persistentReference):
            guard let persistentReference else {
                return .deferred(errSecDecode)
            }
            let status = deleteLegacyItem(
                persistentReference: persistentReference,
                operations: operations
            )
            if status == errSecSuccess || status == errSecItemNotFound {
                return .removed
            }
            logger.error(
                "Legacy Keychain cleanup after save deferred with status \(status, privacy: .public)"
            )
            return .deferred(status)
        case .protectedDataUnavailable(let status), .failed(let status):
            logger.error(
                "Legacy Keychain cleanup lookup deferred with status \(status, privacy: .public)"
            )
            return .deferred(status)
        }
    }

    private static func deleteLegacyItem(
        persistentReference: Data,
        operations: KeychainServiceOperations
    ) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecMatchItemList: [persistentReference],
            kSecUseAuthenticationContext: noninteractiveContext(),
        ]
        return operations.delete(query)
    }
    #else
    private static func cleanupLegacyItem(
        account: String,
        operations: KeychainServiceOperations
    ) -> KeychainLegacyCleanupOutcome {
        .notNeeded
    }
    #endif
}
