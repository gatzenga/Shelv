import Foundation
import SwiftUI
import Combine

@MainActor
class ServerStore: ObservableObject {
    @Published var servers: [SubsonicServer] = []
    @Published var activeServerID: UUID?

    private let saveKey = "shelv_servers"
    private let activeKey = "shelv_active_server"

    init() {
        load()
        activateStoredServer()
    }

    var activeServer: SubsonicServer? {
        guard let id = activeServerID else { return servers.first }
        return servers.first { $0.id == id }
    }

    func activate(server: SubsonicServer) {
        let seenKey = "shelv_seen_servers"
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

    private func activateStoredServer() {
        if let idStr = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: idStr),
           let server = servers.first(where: { $0.id == id }) {
            activeServerID = id
            applyToAPIService(server: server)
        } else if let first = servers.first {
            activeServerID = first.id
            applyToAPIService(server: first)
        }
    }

    private func applyToAPIService(server: SubsonicServer) {
        let password = KeychainService.load(for: server.id)
        SubsonicAPIService.shared.setCredentials(server: server, password: password)
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
            activateStoredServer()
        }

        let serverStableId = server.stableId
        if !serverStableId.isEmpty {
            Task.detached(priority: .utility) {
                await PlayLogService.shared.resetLog(serverId: serverStableId)
                await PlayLogService.shared.resetRegistry(serverId: serverStableId)
                await PlayLogService.shared.removeScrobbles(serverId: serverStableId)
                await CloudKitSyncService.shared.updatePendingCounts()
                await MainActor.run {
                    NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
                }
            }
        }
    }

    func password(for server: SubsonicServer) -> String? {
        KeychainService.load(for: server.id)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([SubsonicServer].self, from: data) {
            servers = decoded
        }
    }
}
