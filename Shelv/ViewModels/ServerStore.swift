import Foundation
import SwiftUI
import Combine

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
        SubsonicAPIService.shared.activeServer = server
        SubsonicAPIService.shared.activePassword = password
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
