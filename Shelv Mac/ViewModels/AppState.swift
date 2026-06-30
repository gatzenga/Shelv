import SwiftUI
import Combine

// MARK: - App State

enum SidePanel {
    case lyrics
    case queue
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isLoggedIn: Bool = false
    @Published var selectedSidebar: SidebarItem? = .discover
    @Published var selectedPlaylist: Playlist? = nil
    @Published var navigationPath = NavigationPath()
    @Published var errorMessage: String?
    @Published var activePanel: SidePanel? = nil

    func togglePanel(_ panel: SidePanel) {
        activePanel = (activePanel == panel) ? nil : panel
    }

    let api = SubsonicAPIService.shared
    let player = AudioPlayerService.shared
    let serverStore = ServerStore()

    private init() {
        #if DEBUG
        if DemoContent.isLargeLibraryFixtureEnabled {
            isLoggedIn = true
            selectedSidebar = .albums
            return
        }
        #endif
        isLoggedIn = api.hasConfig
    }

    // MARK: - Server Management

    /// Testet die Verbindung und fügt den Server zur Liste hinzu.
    func addServer(name: String, serverURL: String, username: String, password: String) async -> Bool {
        let normalizedURL = serverURL.hasPrefix("http://") || serverURL.hasPrefix("https://")
            ? serverURL : "https://" + serverURL
        let config = ServerConfig(serverURL: normalizedURL, username: username, password: password)
        api.setConfig(config)
        do {
            try await api.ping()
            var server = SubsonicServer(name: name, baseURL: normalizedURL, username: username)
            server.remoteUserId = try await api.authLogin()
            serverStore.add(server: server, password: password)
            isLoggedIn = true
            return true
        } catch {
            api.clearConfig()
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Wechselt zum angegebenen Server.
    func switchServer(_ server: SubsonicServer) {
        serverStore.activate(server: server)
        isLoggedIn = api.hasConfig
        resetNavigation()
        // Imperativ statt nur über ContentView.onChange: Wechsel echter Server → Demo
        // ändert isLoggedIn nicht, dadurch re-evaluiert die View nicht zuverlässig und
        // die onChange(activeServerID) feuert evtl. nicht. stop() + Standby atomar hier.
        player.stop()
        RadioStationStore.shared.resetInMemory()
        #if DEBUG
        if api.isDemoActive {
            player.ensureDemoStandby(force: true)
        }
        #endif
    }

    /// Entfernt einen Server. Wenn es der letzte war, wird der Nutzer abgemeldet.
    func deleteServer(_ server: SubsonicServer) {
        let wasActive = serverStore.activeServerID == server.id
        serverStore.delete(server: server)
        if serverStore.servers.isEmpty {
            api.clearConfig()
            player.stop()
            isLoggedIn = false
        } else if wasActive {
            isLoggedIn = api.hasConfig
            resetNavigation()
        }
    }

    private func resetNavigation() {
        navigationPath = NavigationPath()
        selectedSidebar = .discover
        selectedPlaylist = nil
    }

    /// Meldet vollständig ab und löscht alle Server.
    func logout() {
        serverStore.clearAll()
        api.clearConfig()
        player.stop()
        isLoggedIn = false
    }

    // MARK: - Convenience

    var serverDisplayName: String {
        serverStore.activeServer?.displayName ?? api.currentConfig?.serverURL ?? ""
    }

    var username: String {
        api.currentConfig?.username ?? ""
    }
}
