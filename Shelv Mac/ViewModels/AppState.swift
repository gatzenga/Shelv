import SwiftUI
import Combine

// MARK: - App State

enum SidePanel {
    case lyrics
    case queue
    case songInfo
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
    @Published var songInfoSong: Song? = nil

    func togglePanel(_ panel: SidePanel) {
        if activePanel == panel {
            activePanel = nil
            if panel == .songInfo {
                songInfoSong = nil
            }
        } else {
            activePanel = panel
        }
    }

    func showSongInfo(_ song: Song) {
        songInfoSong = song
        activePanel = .songInfo
    }

    func closePanel(_ panel: SidePanel) {
        guard activePanel == panel else { return }
        activePanel = nil
        if panel == .songInfo {
            songInfoSong = nil
        }
    }

    func closeSongInfo() {
        if activePanel == .songInfo {
            activePanel = nil
        }
        songInfoSong = nil
    }

    let api = SubsonicAPIService.shared
    let player = AudioPlayerService.shared
    let serverStore = ServerStore.shared

    private init() {
        #if DEBUG
        if DemoContent.isLargeLibraryFixtureEnabled {
            isLoggedIn = true
            selectedSidebar = .albums
            return
        }
        #endif
        isLoggedIn = !serverStore.servers.isEmpty || api.hasConfig
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.serverStore.waitUntilReady()
            self.isLoggedIn = !self.serverStore.servers.isEmpty
        }
    }

    // MARK: - Server Management

    /// Testet die Verbindung und fügt den Server zur Liste hinzu.
    func addServer(
        name: String,
        serverURL: String,
        username: String,
        password: String,
        secondaryServerURL: String? = nil
    ) async -> Bool {
        errorMessage = nil
        let normalizedURL = serverURL.hasPrefix("http://") || serverURL.hasPrefix("https://")
            ? serverURL : "https://" + serverURL
        let trimmedSecondary = secondaryServerURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var server = SubsonicServer(
            name: name,
            baseURL: normalizedURL,
            username: username,
            secondaryBaseURL: trimmedSecondary.isEmpty ? nil : trimmedSecondary
        )
        do {
            server.remoteUserId = try await api.validatedStableId(
                server: server,
                password: password
            )
            guard await serverStore.add(server: server, password: password) else {
                errorMessage = String(localized: "credential_storage_failed")
                return false
            }
            isLoggedIn = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Wechselt zum angegebenen Server.
    @discardableResult
    func switchServer(_ server: SubsonicServer) async -> Bool {
        errorMessage = nil
        guard await serverStore.activate(server: server) else {
            errorMessage = String(localized: "server_no_longer_available")
            return false
        }
        isLoggedIn = !serverStore.servers.isEmpty
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
        return true
    }

    /// Entfernt einen Server. Wenn es der letzte war, wird der Nutzer abgemeldet.
    @discardableResult
    func deleteServer(_ server: SubsonicServer) async -> Bool {
        errorMessage = nil
        let wasActive = serverStore.activeServerID == server.id
        guard await serverStore.delete(server: server) else {
            errorMessage = String(localized: "credential_storage_failed")
            return false
        }
        if serverStore.servers.isEmpty {
            player.stop()
            isLoggedIn = false
        } else if wasActive {
            isLoggedIn = !serverStore.servers.isEmpty
            resetNavigation()
        }
        return true
    }

    private func resetNavigation() {
        navigationPath = NavigationPath()
        selectedSidebar = .discover
        selectedPlaylist = nil
    }

    /// Meldet vollständig ab und löscht alle Server.
    @discardableResult
    func logout() async -> Bool {
        errorMessage = nil
        guard await serverStore.clearAll() else {
            errorMessage = String(localized: "credential_storage_failed")
            return false
        }
        player.stop()
        isLoggedIn = false
        return true
    }

    // MARK: - Convenience

    var serverDisplayName: String {
        serverStore.activeServer?.displayName ?? api.currentConfig?.serverURL ?? ""
    }

    var username: String {
        api.currentConfig?.username ?? ""
    }
}
