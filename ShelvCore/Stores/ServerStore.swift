import Foundation
import SwiftUI
import Combine
import OSLog

/// Main-actor isolation does not make an async method atomic: another server
/// mutation can enter while the first one awaits Security.framework. This gate
/// serializes each complete persistence + Keychain + activation transaction
/// without blocking a thread.
private actor ServerStoreMutationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<Result: Sendable>(
        _ operation: @MainActor @Sendable () async -> Result
    ) async -> Result {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// A server configuration and credential result captured while the complete
/// lookup is protected by `ServerStoreMutationGate`.
nonisolated struct StoredServerCredentialSnapshot: Sendable {
    let server: SubsonicServer
    let lookup: KeychainCredentialLookup
}

nonisolated enum StoredServerCredentialSelection: Sendable {
    case configuration(UUID)
    case uniqueLegacyIdentifier(String)
}

@MainActor
class ServerStore: ObservableObject {
    static let shared = ServerStore()

    private static let logger = Logger(
        subsystem: "ch.vkugler.Shelv",
        category: "CredentialStorage"
    )

    @Published private(set) var servers: [SubsonicServer] = []
    @Published private(set) var activeServerID: UUID?
    /// Changes whenever the active endpoint, identity, username, or password is
    /// reapplied, including same-ID server edits and primary/secondary URL switches.
    @Published private(set) var activeServerRevision: UInt64 = 0
    private var credentialCache: [UUID: String] = [:]
    private var startupTask: Task<Void, Never>?
    private let mutationGate = ServerStoreMutationGate()
    #if os(macOS)
    private var pendingLegacyServerID: UUID?
    #endif

    // Die alte Desktop-App persistierte unter eigenen Keys — die behalten wir auf
    // macOS bei, damit Bestands-Installationen ihre Server/Logins nicht verlieren.
    #if os(macOS)
    private static let persistenceSaveKey = "shelv_mac_servers"
    private static let persistenceActiveKey = "shelv_mac_active_server"
    private static let persistenceSeenKey = "shelv_mac_seen_servers"
    #else
    private static let persistenceSaveKey = "shelv_servers"
    private static let persistenceActiveKey = "shelv_active_server"
    private static let persistenceSeenKey = "shelv_seen_servers"
    #endif
    private var saveKey: String { Self.persistenceSaveKey }
    private var activeKey: String { Self.persistenceActiveKey }
    private var seenKey: String { Self.persistenceSeenKey }

    init() {
        load()
        #if os(macOS)
        stageLegacyConfigurationForStartupIfNeeded()
        #endif
        // The selected configuration is plain UserDefaults state and can be
        // restored synchronously. System entry points may ask for it before
        // the asynchronous Keychain startup task has finished.
        restoreActiveServerSelection()
        if let server = activeServer {
            SubsonicAPIService.shared.setCredentials(
                server: server,
                password: credentialCache[server.id]
            )
        }
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            #if os(macOS)
            await self.migrateIfNeeded()
            #endif
            await self.activateStoredServer()
        }
    }

    /// Waits until persisted server configuration and credentials have been
    /// restored. Security.framework work runs on KeychainService's queue.
    func waitUntilReady() async {
        let task = startupTask
        await task?.value
    }

    var activeServer: SubsonicServer? {
        guard let id = activeServerID else { return servers.first }
        return servers.first { $0.id == id }
    }

    @discardableResult
    func activate(server: SubsonicServer) async -> Bool {
        await waitUntilReady()
        return await mutationGate.run {
            guard let current = self.servers.first(where: { $0.id == server.id }) else {
                return false
            }
            await self.activateLocked(server: current)
            return true
        }
    }

    private func activateLocked(server: SubsonicServer) async {
        var seen = Set<String>(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        if !seen.contains(server.id.uuidString) {
            UserDefaults.standard.set(true, forKey: "enableFavorites")
            UserDefaults.standard.set(true, forKey: "enablePlaylists")
            UserDefaults.standard.set(true, forKey: PersonalizationPreferenceKey.showFavoritesInLibrary)
            UserDefaults.standard.set(true, forKey: PersonalizationPreferenceKey.showFavoriteActions)
            UserDefaults.standard.set(true, forKey: PersonalizationPreferenceKey.showPlaylistsTab)
            UserDefaults.standard.set(true, forKey: PersonalizationPreferenceKey.showPlaylistActions)
            seen.insert(server.id.uuidString)
            UserDefaults.standard.set(Array(seen), forKey: seenKey)
        }
        if activeServerID != server.id {
            activeServerID = server.id
        }
        UserDefaults.standard.set(server.id.uuidString, forKey: activeKey)
        await applyToAPIService(server: server)
        Task { await ScrobbleService.shared.flushPendingScrobbles() }
    }

    private func activateStoredServer() async {
        restoreActiveServerSelection()
        guard let server = activeServer else { return }
        await applyToAPIService(server: server)
    }

    private func restoreActiveServerSelection() {
        #if os(macOS)
        if let pendingLegacyServerID,
           servers.contains(where: { $0.id == pendingLegacyServerID }) {
            activeServerID = pendingLegacyServerID
            return
        }
        #endif
        if let idString = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: idString),
           servers.contains(where: { $0.id == id }) {
            activeServerID = id
        } else {
            activeServerID = servers.first?.id
        }
    }

    private func applyToAPIService(server: SubsonicServer) async {
        activeServerRevision &+= 1
        let revision = activeServerRevision
        if let password = credentialCache[server.id] {
            SubsonicAPIService.shared.setCredentials(server: server, password: password)
            return
        }

        // Publish the selected identity immediately, but never pretend a
        // credential exists while its background lookup is still pending.
        SubsonicAPIService.shared.setCredentials(server: server, password: nil)
        let lookup = await credentialLookupLocked(for: server)
        guard activeServerRevision == revision,
              activeServer?.id == server.id else {
            return
        }
        guard case .available(let password) = lookup else { return }
        credentialCache[server.id] = password
        SubsonicAPIService.shared.setCredentials(server: server, password: password)
    }

    @discardableResult
    func add(server: SubsonicServer, password: String) async -> Bool {
        await waitUntilReady()
        return await mutationGate.run {
            await self.addLocked(server: server, password: password)
        }
    }

    private func addLocked(server: SubsonicServer, password: String) async -> Bool {
        var server = server
        server.sanitizeURLSlots()
        let saveResult = await KeychainService.save(password: password, for: server.id)
        guard saveResult.succeeded else {
            Self.logger.error("Server add aborted because credential storage failed")
            return false
        }
        credentialCache[server.id] = password
        servers = servers + [server]
        save()
        if servers.count == 1 { await activateLocked(server: server) }
        return true
    }

    @discardableResult
    func update(
        server: SubsonicServer,
        password: String?,
        authenticationIdentityVerified: Bool = false
    ) async -> Bool {
        await waitUntilReady()
        return await mutationGate.run {
            await self.updateLocked(
                server: server,
                password: password,
                authenticationIdentityVerified: authenticationIdentityVerified
            )
        }
    }

    private func updateLocked(
        server: SubsonicServer,
        password: String?,
        authenticationIdentityVerified: Bool
    ) async -> Bool {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            let previous = servers[idx]
            var updated = server
            updated.sanitizeURLSlots()

            let authenticationConfigurationChanged =
                !Self.sameAuthenticationConfiguration(previous, updated)
            guard !authenticationConfigurationChanged
                    || authenticationIdentityVerified else {
                Self.logger.error(
                    "Server update rejected because changed authentication fields were not verified"
                )
                return false
            }

            let previousStableID = Self.nonempty(previous.remoteUserId)
            let updatedStableID = Self.nonempty(updated.remoteUserId)
            let verifiedBackfill = previousStableID == nil
                && updatedStableID != nil
                && !authenticationConfigurationChanged
            let accountIdentityChanged =
                (previousStableID != updatedStableID && !verifiedBackfill)
                || (authenticationConfigurationChanged
                    && (previousStableID == nil || updatedStableID == nil))

            if accountIdentityChanged {
                guard await invalidateConfigScopedCaches(serverID: previous.id) else {
                    Self.logger.error(
                        "Server update aborted because old account caches could not be invalidated"
                    )
                    return false
                }
            }

            let passwordChanged = password.map {
                credentialCache[server.id] != $0
            } ?? false
            if let password, passwordChanged {
                let saveResult = await KeychainService.save(
                    password: password,
                    for: server.id
                )
                guard saveResult.succeeded else {
                    Self.logger.error("Server update aborted because credential storage failed")
                    return false
                }
                credentialCache[server.id] = password
            }

            if accountIdentityChanged {
                await PlayLogService.shared.removeScrobbles(
                    serverConfigId: previous.id.uuidString
                )
            }

            var updatedServers = servers
            updatedServers[idx] = updated
            servers = updatedServers
            save()
            let runtimeConfigurationChanged =
                !Self.sameCredentialRequestIdentity(previous, updated)
            if activeServerID == server.id,
               runtimeConfigurationChanged || passwordChanged {
                await applyToAPIService(server: updated)
            }
            if verifiedBackfill, let updatedStableID {
                Task {
                    await PlayLogService.shared.migrateServerId(
                        from: previous.id.uuidString,
                        to: updatedStableID
                    )
                }
            }
            Task { await ScrobbleService.shared.flushPendingScrobbles() }
            return true
        }
        return false
    }

    func setURLSlot(for serverID: UUID, slot: ServerURLSlot) async {
        await waitUntilReady()
        await mutationGate.run {
            await self.setURLSlotLocked(for: serverID, slot: slot)
        }
    }

    private func setURLSlotLocked(for serverID: UUID, slot: ServerURLSlot) async {
        guard let idx = servers.firstIndex(where: { $0.id == serverID }) else { return }
        if slot == .secondary && !servers[idx].hasSecondaryURL { return }
        if servers[idx].activeURLSlot == slot { return }

        var updated = servers[idx]
        updated.activeURLSlot = slot
        updated.sanitizeURLSlots()
        var updatedServers = servers
        updatedServers[idx] = updated
        servers = updatedServers
        save()

        if activeServerID == serverID {
            await applyToAPIService(server: updated)
        }
        Task { await ScrobbleService.shared.flushPendingScrobbles() }
    }

    func toggleURLSlot(for server: SubsonicServer) async {
        let target: ServerURLSlot = server.isUsingSecondaryURL ? .primary : .secondary
        await setURLSlot(for: server.id, slot: target)
    }

    @discardableResult
    func delete(server: SubsonicServer) async -> Bool {
        await waitUntilReady()
        return await mutationGate.run {
            await self.deleteLocked(server: server)
        }
    }

    private func deleteLocked(server: SubsonicServer) async -> Bool {
        guard let current = servers.first(where: { $0.id == server.id }) else {
            return false
        }
        let wasActive = activeServer?.id == current.id
        let deletion = await KeychainService.delete(for: current.id)
        guard deletion.succeeded else {
            Self.logger.error("Server delete aborted because credential cleanup failed")
            return false
        }
        credentialCache.removeValue(forKey: current.id)
        servers = servers.filter { $0.id != current.id }
        save()
        if wasActive {
            if let next = servers.first {
                await activateLocked(server: next)
            } else {
                activeServerID = nil
                UserDefaults.standard.removeObject(forKey: activeKey)
                clearAPIService()
            }
        }

        let serverStableId = current.stableId
        let serverConfigID = current.id.uuidString
        let shouldDeleteStableData = !serverStableId.isEmpty
            && !servers.contains(where: { $0.stableId == serverStableId })
        Task.detached(priority: .utility) {
            if shouldDeleteStableData {
                await PlayLogService.shared.resetLog(serverId: serverStableId)
                await PlayLogService.shared.resetRegistry(serverId: serverStableId)
                await DownloadService.shared.deleteAllForServer(serverStableId)
            }
            // Neue Outbox-Zeilen sind an die lokale Konfiguration gebunden. Nur
            // diese löschen; dieselbe Remote-ID kann in mehreren Configs vorkommen.
            await PlayLogService.shared.removeScrobbles(serverConfigId: serverConfigID)
            await CloudKitSyncService.shared.updatePendingCounts()
            await MainActor.run {
                NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
                NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
            }
        }
        return true
    }

    /// Fast UI access to a credential already restored in this process. This
    /// never calls Security.framework and is therefore safe from synchronous
    /// view construction and rendering paths.
    func password(for server: SubsonicServer) -> String? {
        credentialCache[server.id]
    }

    /// Returns the lossless credential state through the same transaction gate
    /// as server updates and deletes. This prevents a lookup that started for
    /// old state from repopulating the cache after a newer mutation completed.
    func credentialLookup(
        for server: SubsonicServer
    ) async -> KeychainCredentialLookup {
        await waitUntilReady()
        return await mutationGate.run {
            guard let current = self.servers.first(where: { $0.id == server.id }) else {
                return .missing
            }
            guard Self.sameCredentialRequestIdentity(current, server) else {
                return .missing
            }
            return await self.credentialLookupLocked(for: current)
        }
    }

    /// Captures the current server object and its credential as one serialized
    /// snapshot. Background delivery code uses this instead of pairing a stale
    /// pre-await server value with a post-await password.
    func credentialSnapshot(
        for selection: StoredServerCredentialSelection,
        requireActive: Bool
    ) async -> StoredServerCredentialSnapshot? {
        await waitUntilReady()
        return await mutationGate.run {
            guard let server = self.server(matching: selection),
                  !requireActive || self.activeServer?.id == server.id else {
                return nil
            }
            let lookup = await self.credentialLookupLocked(for: server)
            guard let current = self.server(matching: selection),
                  current.id == server.id,
                  Self.sameCredentialRequestIdentity(current, server),
                  !requireActive || self.activeServer?.id == server.id else {
                return nil
            }
            return StoredServerCredentialSnapshot(
                server: current,
                lookup: lookup
            )
        }
    }

    /// Revalidates a previously captured pair after another suspension point.
    /// The check itself joins the mutation gate, so an in-flight same-ID edit
    /// must finish before endpoint, identity, and cached password are compared.
    func isCredentialSnapshotCurrent(
        _ snapshot: StoredServerCredentialSnapshot,
        selection: StoredServerCredentialSelection,
        requireActive: Bool
    ) async -> Bool {
        await waitUntilReady()
        return await mutationGate.run {
            guard let current = self.server(matching: selection),
                  current.id == snapshot.server.id,
                  !requireActive || self.activeServer?.id == snapshot.server.id,
                  Self.sameCredentialRequestIdentity(current, snapshot.server)
            else {
                return false
            }
            return switch snapshot.lookup {
            case .available(let password):
                self.credentialCache[snapshot.server.id] == password
            case .missing, .protectedDataUnavailable, .failed:
                self.credentialCache[snapshot.server.id] == nil
            }
        }
    }

    private func server(
        matching selection: StoredServerCredentialSelection
    ) -> SubsonicServer? {
        switch selection {
        case .configuration(let id):
            return servers.first { $0.id == id }
        case .uniqueLegacyIdentifier(let identifier):
            let matches = servers.filter {
                $0.stableId == identifier || $0.id.uuidString == identifier
            }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private func credentialLookupLocked(
        for server: SubsonicServer
    ) async -> KeychainCredentialLookup {
        if let cached = credentialCache[server.id] {
            return .available(cached)
        }
        let lookup = await KeychainService.lookup(for: server.id)
        if case .available(let password) = lookup {
            credentialCache[server.id] = password
        }
        return lookup
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func sameAuthenticationConfiguration(
        _ lhs: SubsonicServer,
        _ rhs: SubsonicServer
    ) -> Bool {
        lhs.baseURL == rhs.baseURL
            && lhs.secondaryBaseURL == rhs.secondaryBaseURL
            && lhs.username == rhs.username
    }

    /// Removes caches whose ownership is the local configuration UUID before
    /// that UUID is repointed at a different authenticated account.
    private func invalidateConfigScopedCaches(serverID: UUID) async -> Bool {
        do {
            try await LibraryDatabase.shared.clear(serverKey: serverID.uuidString)
        } catch {
            Self.logger.error(
                "Library database invalidation failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        let filesRemoved = await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var succeeded = true

            let libraryDirectory = fileManager
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("shelv_library", isDirectory: true)
            if fileManager.fileExists(atPath: libraryDirectory.path) {
                do {
                    let suffix = "_\(serverID.uuidString).json"
                    for url in try fileManager.contentsOfDirectory(
                        at: libraryDirectory,
                        includingPropertiesForKeys: nil
                    ) where url.lastPathComponent.hasSuffix(suffix) {
                        do {
                            try fileManager.removeItem(at: url)
                        } catch {
                            succeeded = false
                        }
                    }
                } catch {
                    succeeded = false
                }
            }

            let encodedID = serverID.uuidString.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics
            ) ?? serverID.uuidString
            for directory in [
                FileManager.SearchPathDirectory.applicationSupportDirectory,
                .cachesDirectory,
            ] {
                let radioDirectory = fileManager
                    .urls(for: directory, in: .userDomainMask)[0]
                    .appendingPathComponent("Shelv", isDirectory: true)
                    .appendingPathComponent("Radio", isDirectory: true)
                for filename in [
                    "\(encodedID).stations.json",
                    "\(encodedID).json",
                ] {
                    let url = radioDirectory.appendingPathComponent(filename)
                    guard fileManager.fileExists(atPath: url.path) else { continue }
                    do {
                        try fileManager.removeItem(at: url)
                    } catch {
                        succeeded = false
                    }
                }
            }
            return succeeded
        }.value

        guard filesRemoved else { return false }
        UserDefaults.standard.removeObject(forKey: "shelv_albumCount_\(serverID)")
        UserDefaults.standard.removeObject(forKey: "shelv_artistCount_\(serverID)")
        UserDefaults.standard.removeObject(forKey: "shelv_songCount_\(serverID)")
        UserDefaults.standard.removeObject(forKey: "shelv_lastSync_\(serverID)")
        return true
    }

    private static func sameCredentialRequestIdentity(
        _ lhs: SubsonicServer,
        _ rhs: SubsonicServer
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.baseURL == rhs.baseURL
            && lhs.secondaryBaseURL == rhs.secondaryBaseURL
            && lhs.activeURLSlot == rhs.activeURLSlot
            && lhs.username == rhs.username
            && lhs.remoteUserId == rhs.remoteUserId
    }

    /// Loads and caches a credential without blocking the main actor. Callers
    /// that need a definitive value (startup, editing, or scrobbling)
    /// must use this method rather than assuming the fast cache is populated.
    func loadPassword(for server: SubsonicServer) async -> String? {
        guard case .available(let password) = await credentialLookup(for: server) else {
            return nil
        }
        return password
    }

    /// Entfernt alle Server samt Keychain-Einträgen und lokaler Historie
    /// (macOS-Serververwaltung: „Alle Server löschen").
    @discardableResult
    func clearAll() async -> Bool {
        await waitUntilReady()
        return await mutationGate.run {
            await self.clearAllLocked()
        }
    }

    private func clearAllLocked() async -> Bool {
        let previousActiveServerID = activeServerID
        var removedServers: [SubsonicServer] = []
        var retainedServers: [SubsonicServer] = []
        for server in servers {
            if (await KeychainService.delete(for: server.id)).succeeded {
                removedServers.append(server)
                credentialCache.removeValue(forKey: server.id)
            } else {
                retainedServers.append(server)
            }
        }

        servers = retainedServers
        if retainedServers.isEmpty {
            activeServerID = nil
            UserDefaults.standard.removeObject(forKey: saveKey)
            UserDefaults.standard.removeObject(forKey: activeKey)
            clearAPIService()
        } else {
            save()
            if let previousActiveServerID,
               retainedServers.contains(where: { $0.id == previousActiveServerID }) {
                activeServerID = previousActiveServerID
            } else if let first = retainedServers.first {
                activeServerID = first.id
                UserDefaults.standard.set(first.id.uuidString, forKey: activeKey)
                await applyToAPIService(server: first)
            }
            Self.logger.error(
                "Clear-all retained \(retainedServers.count, privacy: .public) server configuration(s) whose credentials could not be deleted"
            )
        }

        let retainedStableIds = Set(
            retainedServers.map(\.stableId).filter { !$0.isEmpty }
        )
        let stableIds = Set(
            removedServers.map(\.stableId).filter { !$0.isEmpty }
        ).subtracting(retainedStableIds)
        let configIds = removedServers.map { $0.id.uuidString }

        guard !stableIds.isEmpty || !configIds.isEmpty else {
            return retainedServers.isEmpty
        }
        let allServersCleared = retainedServers.isEmpty
        Task.detached(priority: .utility) {
            for sid in stableIds {
                await PlayLogService.shared.resetLog(serverId: sid)
                await PlayLogService.shared.resetRegistry(serverId: sid)
            }
            if allServersCleared {
                await PlayLogService.shared.removeAllScrobbles()
            } else {
                for configID in configIds {
                    await PlayLogService.shared.removeScrobbles(
                        serverConfigId: configID
                    )
                }
            }
            await CloudKitSyncService.shared.updatePendingCounts()
            await MainActor.run {
                NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
            }
        }
        return retainedServers.isEmpty
    }

    private func clearAPIService() {
        SubsonicAPIService.shared.activeServer = nil
        SubsonicAPIService.shared.activePassword = nil
        activeServerRevision &+= 1
    }

    #if os(macOS)
    /// Exposes a very old single-server configuration synchronously so system
    /// entry points can select the correct server during a cold launch. Secure
    /// persistence and deletion of the legacy defaults remain success-gated in
    /// `migrateIfNeeded()`.
    private func stageLegacyConfigurationForStartupIfNeeded() {
        guard UserDefaults.standard.data(forKey: saveKey) == nil,
              let data = UserDefaults.standard.data(forKey: "serverConfig"),
              let legacy = try? JSONDecoder().decode(ServerConfig.self, from: data)
        else { return }

        let server = SubsonicServer(
            name: "",
            baseURL: legacy.serverURL,
            username: legacy.username
        )
        pendingLegacyServerID = server.id
        credentialCache[server.id] = legacy.password
        servers = [server] + servers.filter { $0.baseURL == demoBaseURL }
    }

    /// Migriert den einzelnen Legacy-`serverConfig`-Eintrag sehr alter
    /// Desktop-Installationen ins Multi-Server-Format.
    private func migrateIfNeeded() async {
        guard UserDefaults.standard.data(forKey: saveKey) == nil,
              let data = UserDefaults.standard.data(forKey: "serverConfig"),
              let legacy = try? JSONDecoder().decode(ServerConfig.self, from: data)
        else { return }

        let server = pendingLegacyServerID.flatMap { id in
            servers.first { $0.id == id }
        } ?? SubsonicServer(
            name: "",
            baseURL: legacy.serverURL,
            username: legacy.username
        )
        credentialCache[server.id] = legacy.password
        let saveResult = await KeychainService.save(password: legacy.password, for: server.id)
        guard saveResult.succeeded,
              let encoded = try? JSONEncoder().encode([server])
        else {
            Self.logger.error(
                "Legacy server migration deferred because secure persistence failed"
            )
            return
        }
        credentialCache[server.id] = legacy.password
        servers = [server]
        #if DEBUG
        servers.append(DemoContent.server)
        #endif
        UserDefaults.standard.set(encoded, forKey: saveKey)
        UserDefaults.standard.set(server.id.uuidString, forKey: activeKey)
        UserDefaults.standard.removeObject(forKey: "serverConfig")
        pendingLegacyServerID = nil
    }
    #endif

    /// String-Konstante (statt DemoContent), damit der Filter auch in Release-Builds kompiliert,
    /// wo `DemoContent` nicht existiert. Hält den Demo-Server zuverlässig aus der Persistenz.
    private let demoBaseURL = "demo://shelv"

    private func save() {
        // Demo-Server nie persistieren — sonst könnte er über die (zwischen Debug und Release
        // geteilten) UserDefaults in einen Release-Build durchsickern.
        let persistable = servers.filter { $0.baseURL != demoBaseURL }
        if let data = try? JSONEncoder().encode(persistable) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([SubsonicServer].self, from: data) {
            // Etwaige persistierte Demo-Server immer verwerfen (auch im Release).
            servers = decoded.filter { $0.baseURL != demoBaseURL }.map {
                var server = $0
                server.sanitizeURLSlots()
                return server
            }
        }
        #if DEBUG
        // Frischen Demo-Server rein in-memory anhängen — nur in Debug-Builds.
        servers.append(DemoContent.server)
        #endif
    }
}
