import AppIntents
import SwiftUI

let appLang: String = Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"

extension Notification.Name {
    static let addSongsToPlaylist = Notification.Name("shelv.addSongsToPlaylist")
    static let showToast = Notification.Name("shelv.showToast")
    // .recapRegistryUpdated liegt jetzt geteilt in ShelvCore (DownloadService.swift).
}

@main
struct Shelv_DesktopApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var serverStore = ServerStore.shared
    private let _playTracker = PlayTracker.shared
    @AppStorage("appColorScheme") private var storedColorScheme: AppColorScheme = .system
    @AppStorage("themeColor") private var themeColorName: String = "violet"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        // AAC-Transcoding bleibt deaktiviert — Migration falls vorher gesetzt.
        let d = UserDefaults.standard
        if d.string(forKey: "transcodingWifiCodec") == "aac" { d.set("raw", forKey: "transcodingWifiCodec") }
        if d.string(forKey: "transcodingCellularCodec") == "aac" { d.set("raw", forKey: "transcodingCellularCodec") }
        if d.string(forKey: "transcodingDownloadCodec") == "aac" { d.set("raw", forKey: "transcodingDownloadCodec") }
        PersonalizationSettings.registerDefaults()
        ShelvDefaultSettings.registerDefaults()
        ShelvPlatformAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(serverStore)
                .environmentObject(LyricsStore.shared)
                .environmentObject(CloudKitSyncService.shared.status)
                .environmentObject(RecapStore.shared)
                .environmentObject(LibraryViewModel.shared)
                .environmentObject(DownloadStore.shared)
                .environmentObject(OfflineModeService.shared)
                .frame(minWidth: 1000, minHeight: 600)
                .task { await LyricsStore.shared.setup() }
                .task {
                    await serverStore.waitUntilReady()
                    Task.detached(priority: .utility) {
                        await StreamCacheService.shared.cleanupOldFiles()
                    }
                    await PlayLogService.shared.setup()
                    await DownloadDatabase.shared.setup()
                    await DownloadService.shared.setup()
                    if let active = serverStore.activeServer {
                        await DownloadStore.shared.setActiveServer(active.stableId)
                    }
                    // DB ist jetzt bereit — sicherstellt dass Downloads geladen werden,
                    // auch wenn setActiveServer oben durch den Guard blockiert wurde
                    await DownloadStore.shared.reload()
                    let api = SubsonicAPIService.shared
                    for server in serverStore.servers where server.remoteUserId == nil {
                        guard let pw = await serverStore.loadPassword(for: server) else { continue }
                        do {
                            let uid = try await api.authLogin(server: server, password: pw)
                            var updated = server
                            updated.remoteUserId = uid
                            _ = await serverStore.update(server: updated, password: nil)
                            print("[ServerID] Backfill OK \(server.displayName): \(uid)")
                        } catch {
                            print("[ServerID] Backfill FAILED \(server.displayName): \(error)")
                        }
                    }
                    if let active = serverStore.activeServer {
                        print("[ServerID] Active server stableId: \(active.stableId)")
                    }
                    await CloudKitSyncService.shared.setup()
                }
                .task(id: serverStore.activeServerRevision) {
                    await serverStore.waitUntilReady()
                    let revision = serverStore.activeServerRevision
                    await Task.yield()
                    guard revision == serverStore.activeServerRevision else { return }
                    LibraryViewModel.shared.reset()
                    guard let server = serverStore.activeServer else { return }
                    OfflineModeService.shared.prepareInitialServerErrorPresentation()
                    await LibraryViewModel.shared.loadAlbums()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision,
                          let currentServer = serverStore.activeServer,
                          currentServer.id == server.id
                    else { return }
                    await LibraryViewModel.shared.loadArtists()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await LibraryViewModel.shared.loadStarred()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await LibraryViewModel.shared.loadPlaylists(force: true)
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await RecapStore.shared.setup(serverId: currentServer.stableId)
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await DownloadStore.shared.setActiveServer(currentServer.stableId)
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    PinnedPlaylistStore.shared.setActiveServer(currentServer.stableId)
                    await QueueSyncService.shared.checkForRemoteQueue()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await runKeepLibraryOfflineCheck(serverId: currentServer.stableId)
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    ShelvPlatformAppShortcuts.updateAppShortcutParameters()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    ShelvPlatformAppShortcuts.updateAppShortcutParameters()
                    // syncNow prüft die Remote-Queue automatisch mit.
                    Task { await CloudKitSyncService.shared.syncNow() }
                    if let active = appState.serverStore.activeServer {
                        Task { await runKeepLibraryOfflineCheck(serverId: active.stableId) }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await CloudKitSyncService.shared.syncNow() }
                    if let active = appState.serverStore.activeServer {
                        Task { await runKeepLibraryOfflineCheck(serverId: active.stableId) }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
                    guard let server = appState.serverStore.activeServer else { return }
                    Task { await RecapStore.shared.loadEntries(serverId: server.stableId) }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 760)
        .commands {
            SidebarCommands()

            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "about_shelv")) {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }

            CommandMenu(String(localized: "profile")) {
                if appState.isLoggedIn, let active = appState.serverStore.activeServer {
                    Text(active.displayName)
                    Text(appState.username)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "not_logged_in"))
                        .foregroundStyle(.secondary)
                }
                Divider()
                ServerManagementMenuItem()
                Divider()
                Button(String(localized: "log_out")) {
                    Task {
                        guard !(await appState.logout()) else { return }
                        NotificationCenter.default.post(
                            name: .showToast,
                            object: appState.errorMessage
                                ?? String(localized: "credential_storage_failed")
                        )
                    }
                }
                .disabled(!appState.isLoggedIn)
            }

            CommandGroup(replacing: .help) {
                Link(String(localized: "shelv_on_github"), destination: URL(string: "https://github.com/gatzenga/Shelv-Desktop")!)
                Link(String(localized: "navidrome_documentation"), destination: URL(string: "https://www.navidrome.org/docs/")!)
                Divider()
                Link(String(localized: "developer_website"), destination: URL(string: "https://vkugler.app")!)
                Link(String(localized: "privacy_policy"), destination: URL(string: "https://vkugler.app/shelv_privacy.html")!)
                Link(String(localized: "contact"), destination: URL(string: "mailto:contact@vkugler.app")!)
                Link("Discord", destination: URL(string: "https://discord.gg/UdJK5mpmZu")!)
            }

            CommandMenu(String(localized: "playback")) {
                Button(String(localized: "play_pause")) {
                    AppState.shared.player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                Divider()
                Button(String(localized: "next_track")) {
                    AppState.shared.player.next(triggeredByUser: true)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                Button(String(localized: "previous_track")) {
                    AppState.shared.player.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                DataSaverMenuItem()
                Divider()
                OfflineModeMenuItem()
        }
    }
        Window(String(localized: "insights"), id: "insights") {
            InsightsView()
                .environmentObject(appState)
                .environmentObject(appState.serverStore)
                .tint(AppTheme.color(for: themeColorName))
                .environment(\.themeColor, AppTheme.color(for: themeColorName))
        }
        .windowResizability(.contentSize)

        Window(String(localized: "recap"), id: "recap") {
            RecapView()
                .environmentObject(appState)
                .environmentObject(appState.serverStore)
                .environmentObject(RecapStore.shared)
                .environmentObject(LibraryViewModel.shared)
                .tint(AppTheme.color(for: themeColorName))
                .environment(\.themeColor, AppTheme.color(for: themeColorName))
                .frame(width: 720, height: 660)
        }
        .windowResizability(.contentSize)

        Window(String(localized: "manage_servers"), id: "server-management") {
            ServerManagementView()
                .environmentObject(appState)
                .environmentObject(appState.serverStore)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 660, height: 660)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.serverStore)
                .environmentObject(LyricsStore.shared)
                .tint(AppTheme.color(for: themeColorName))
                .environment(\.themeColor, AppTheme.color(for: themeColorName))
        }
    }

    @MainActor
    private func runKeepLibraryOfflineCheck(serverId: String, force: Bool = false) async {
        guard UserDefaults.standard.bool(forKey: "enableDownloads") else { return }
        guard KeepLibraryOfflineService.shared.isEnabled(serverId: serverId) else { return }
        await DownloadService.shared.waitForRestoredInflightTasks()
        await LibraryViewModel.shared.loadAlbums()
        let recapIds = UserDefaults.standard.bool(forKey: "recapEnabled")
            ? Array(RecapStore.shared.recapPlaylistIds)
            : []
        let favorites = UserDefaults.standard.object(forKey: "enableFavorites") as? Bool ?? true
        await KeepLibraryOfflineService.shared.checkAndDownload(
            serverId: serverId,
            libraryAlbums: LibraryViewModel.shared.albums,
            favorites: favorites,
            recapPlaylistIds: recapIds,
            force: force
        )
    }
}

struct ServerManagementMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "manage_servers_2")) {
            openWindow(id: "server-management")
        }
    }
}

struct InsightsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "insights_2")) {
            openWindow(id: "insights")
        }
    }
}

struct RecapMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "recap_2")) {
            openWindow(id: "recap")
        }
    }
}

struct DataSaverMenuItem: View {
    @AppStorage("dataSaverEnabled") private var dataSaverEnabled = false
    @AppStorage("transcodingEnabled") private var transcodingEnabled = false

    var body: some View {
        Toggle(String(localized: "data_saver"), isOn: $dataSaverEnabled)
            .disabled(!transcodingEnabled)
    }
}

struct OfflineModeMenuItem: View {
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("enableDownloads") private var enableDownloads = true

    var body: some View {
        Toggle(
            String(localized: "offline_mode"),
            isOn: Binding(
                get: { offlineMode.isOffline },
                set: { if $0 { offlineMode.enterOfflineMode() } else { offlineMode.exitOfflineMode() } }
            )
        )
        .disabled(!enableDownloads)
    }
}
