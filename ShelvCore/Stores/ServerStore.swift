import Foundation
import SwiftUI
import Combine

@MainActor
class ServerStore: ObservableObject {
    @Published var servers: [SubsonicServer] = []
    @Published var activeServerID: UUID?

    // Die alte Desktop-App persistierte unter eigenen Keys — die behalten wir auf
    // macOS bei, damit Bestands-Installationen ihre Server/Logins nicht verlieren.
    #if os(macOS)
    private let saveKey = "shelv_mac_servers"
    private let activeKey = "shelv_mac_active_server"
    private let seenKey = "shelv_mac_seen_servers"
    #else
    private let saveKey = "shelv_servers"
    private let activeKey = "shelv_active_server"
    private let seenKey = "shelv_seen_servers"
    #endif

    init() {
        #if os(macOS)
        migrateIfNeeded()
        #endif
        load()
        activateStoredServer()
    }

    var activeServer: SubsonicServer? {
        guard let id = activeServerID else { return servers.first }
        return servers.first { $0.id == id }
    }

    func activate(server: SubsonicServer) {
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
        if let password {
            // Transparente Migration: bestehende Items auf AfterFirstUnlock upgraden
            KeychainService.save(password: password, for: server.id)
        }
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
                await DownloadService.shared.deleteAllForServer(serverStableId)
                await CloudKitSyncService.shared.updatePendingCounts()
                await MainActor.run {
                    NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
                    NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
                }
            }
        }
    }

    func password(for server: SubsonicServer) -> String? {
        KeychainService.load(for: server.id)
    }

    /// Entfernt alle Server samt Keychain-Einträgen und lokaler Historie
    /// (macOS-Serververwaltung: „Alle Server löschen").
    func clearAll() {
        let stableIds = servers.map { $0.stableId }.filter { !$0.isEmpty }
        for server in servers { KeychainService.delete(for: server.id) }
        servers = []
        activeServerID = nil
        UserDefaults.standard.removeObject(forKey: saveKey)
        UserDefaults.standard.removeObject(forKey: activeKey)

        guard !stableIds.isEmpty else { return }
        Task.detached(priority: .utility) {
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

    #if os(macOS)
    /// Migriert den einzelnen Legacy-`serverConfig`-Eintrag sehr alter
    /// Desktop-Installationen ins Multi-Server-Format.
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
            servers = decoded.filter { $0.baseURL != demoBaseURL }
        }
        #if DEBUG
        // Frischen Demo-Server rein in-memory anhängen — nur in Debug-Builds.
        servers.append(DemoContent.server)
        #endif
    }
}
