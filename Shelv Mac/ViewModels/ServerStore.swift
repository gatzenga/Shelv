import Foundation
import SwiftUI
import Combine

@MainActor
class ServerStore: ObservableObject {
    @Published var servers: [SubsonicServer] = []
    @Published var activeServerID: UUID?

    private let saveKey = "shelv_mac_servers"
    private let activeKey = "shelv_mac_active_server"

    init() {
        migrateIfNeeded()
        load()
        activateStoredServer()
    }

    var activeServer: SubsonicServer? {
        guard let id = activeServerID else { return servers.first }
        return servers.first { $0.id == id }
    }

    func activate(server: SubsonicServer) {
        let seenKey = "shelv_mac_seen_servers"
        var seen = Set<String>(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        if !seen.contains(server.id.uuidString) {
            UserDefaults.standard.set(true, forKey: "enableFavorites")
            UserDefaults.standard.set(true, forKey: "enablePlaylists")
            seen.insert(server.id.uuidString)
            UserDefaults.standard.set(Array(seen), forKey: seenKey)
        }
        activeServerID = server.id
        UserDefaults.standard.set(server.id.uuidString, forKey: activeKey)
        applyToAPIService(server: server)
    }

    func add(server: SubsonicServer, password: String) {
        KeychainService.save(password: password, for: server.id)
        servers.append(server)
        save()
        if servers.count == 1 { activate(server: server) }
    }

    func update(server: SubsonicServer, password: String?) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
            if let pw = password { KeychainService.save(password: pw, for: server.id) }
            save()
            if activeServerID == server.id { applyToAPIService(server: server) }
        }
    }

    func delete(server: SubsonicServer) {
        KeychainService.delete(for: server.id)
        servers.removeAll { $0.id == server.id }
        save()
        if activeServerID == server.id {
            activeServerID = nil
            activateStoredServer()
        }

        let serverStableId = server.stableId
        if !serverStableId.isEmpty {
            Task.detached(priority: .userInitiated) {
                await PlayLogService.shared.resetLog(serverId: serverStableId)
                await PlayLogService.shared.resetRegistry(serverId: serverStableId)
                await PlayLogService.shared.removeScrobbles(serverId: serverStableId)
                await DownloadService.shared.deleteAllForServer(serverStableId)
                await CloudKitSyncService.shared.updatePendingCounts()
                await MainActor.run {
                    NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
                    NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
                }
            }
        }
    }

    func clearAll() {
        let stableIds = servers.map { $0.stableId }.filter { !$0.isEmpty }
        for server in servers { KeychainService.delete(for: server.id) }
        servers = []
        activeServerID = nil
        UserDefaults.standard.removeObject(forKey: saveKey)
        UserDefaults.standard.removeObject(forKey: activeKey)

        guard !stableIds.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            for sid in stableIds {
                await PlayLogService.shared.resetLog(serverId: sid)
                await PlayLogService.shared.resetRegistry(serverId: sid)
                await PlayLogService.shared.removeScrobbles(serverId: sid)
            }
            await CloudKitSyncService.shared.updatePendingCounts()
            await MainActor.run {
                NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
            }
        }
    }

    func password(for server: SubsonicServer) -> String? {
        KeychainService.load(for: server.id)
    }

    // MARK: - Private

    private func activateStoredServer() {
        if let idStr = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: idStr),
           let server = servers.first(where: { $0.id == id }) {
            activeServerID = id
            applyToAPIService(server: server)
        } else if let first = servers.first(where: { $0.baseURL != demoBaseURL }) {
            activeServerID = first.id
            applyToAPIService(server: first)
        }
    }

    private func applyToAPIService(server: SubsonicServer) {
        var password = KeychainService.load(for: server.id) ?? ""
        #if DEBUG
        if server.baseURL == demoBaseURL { password = "demo" }
        #endif
        let config = ServerConfig(serverURL: server.baseURL, username: server.username, password: password)
        SubsonicAPIService.shared.setConfig(config)
    }

    private let demoBaseURL = "demo://shelv"

    private func save() {
        let persistable = servers.filter { $0.baseURL != demoBaseURL }
        if let data = try? JSONEncoder().encode(persistable) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([SubsonicServer].self, from: data) {
            servers = decoded.filter { $0.baseURL != demoBaseURL }
        }
        #if DEBUG
        servers.append(DemoContent.server)
        #endif
    }

    /// Migrates a single legacy `serverConfig` UserDefaults entry to the new multi-server format.
    private func migrateIfNeeded() {
        guard UserDefaults.standard.data(forKey: saveKey) == nil,
              let data = UserDefaults.standard.data(forKey: "serverConfig"),
              let legacy = try? JSONDecoder().decode(ServerConfig.self, from: data)
        else { return }

        let server = SubsonicServer(name: "", baseURL: legacy.serverURL, username: legacy.username)
        KeychainService.save(password: legacy.password, for: server.id)
        if let encoded = try? JSONEncoder().encode([server]) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
            UserDefaults.standard.set(server.id.uuidString, forKey: activeKey)
        }
        UserDefaults.standard.removeObject(forKey: "serverConfig")
    }
}
