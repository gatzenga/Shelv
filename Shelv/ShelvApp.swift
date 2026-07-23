import AppIntents
@preconcurrency import Combine
import Intents
import SwiftUI

let appLang: String = Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"

// .recapRegistryUpdated ist nach ShelvCore (DownloadService.swift) gewandert —
// der Name wird von allen drei Plattformen gebraucht.

final class BackgroundDownloadHandler {
    static let shared = BackgroundDownloadHandler()
    private let lock = NSLock()
    private var handlers: [String: () -> Void] = [:]

    func store(_ handler: @escaping () -> Void, for identifier: String) {
        lock.withLock { handlers[identifier] = handler }
    }

    func consume(for identifier: String) -> (() -> Void)? {
        lock.withLock { handlers.removeValue(forKey: identifier) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        guard intent is INPlayMediaIntent else { return nil }
        return ShelvSiriMediaIntentHandler.shared
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloadHandler.shared.store(completionHandler, for: identifier)
    }
}


func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}

@main
struct ShelvApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serverStore = ServerStore.shared
    @StateObject private var offlineMode = OfflineModeService.shared
    private let downloadActivity = DownloadActivityStore.shared
    private let _playTracker = PlayTracker.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("preventSleepDuringDownloads") private var preventSleepDuringDownloads = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var musicLibraryReloadTask: Task<Void, Never>?

    init() {
        // AAC-Transcoding bleibt deaktiviert — Migration falls vorher gesetzt.
        let d = UserDefaults.standard
        if d.string(forKey: "transcodingWifiCodec") == "aac" { d.set("raw", forKey: "transcodingWifiCodec") }
        if d.string(forKey: "transcodingCellularCodec") == "aac" { d.set("raw", forKey: "transcodingCellularCodec") }
        if d.string(forKey: "transcodingDownloadCodec") == "aac" { d.set("raw", forKey: "transcodingDownloadCodec") }
        PersonalizationSettings.registerDefaults()
        ShelvDefaultSettings.registerDefaults()
        LibraryDerivedStatePrewarmer.activate()
        let shortcutPlaybackCoordinator = ShortcutPlaybackCoordinator.shared
        AppDependencyManager.shared.add(dependency: shortcutPlaybackCoordinator)
        ShelvAppShortcuts.updateAppShortcutParameters()
        SiriMediaAppSelectionService.shared.restoreUserContext()
    }

    private var preferredScheme: ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .personalizationSwipeEnvironment()
                .environmentObject(serverStore)
                .environmentObject(LibraryStore.shared)
                .environmentObject(AudioPlayerService.shared)
                .environmentObject(LyricsStore.shared)
                .environmentObject(RecapStore.shared)
                .environmentObject(CloudKitSyncService.shared.status)
                .environmentObject(DownloadStore.shared)
                .environmentObject(offlineMode)
                .tint(AppTheme.color(for: themeColorName))
                .preferredColorScheme(preferredScheme)
                .task {
                    await LyricsStore.shared.setup()
                }
                .task(id: serverStore.activeServerRevision) {
                    await serverStore.waitUntilReady()
                    let revision = serverStore.activeServerRevision
                    await Task.yield()
                    guard revision == serverStore.activeServerRevision else { return }
                    LibraryStore.shared.resetInMemory()
                    guard let server = serverStore.activeServer else { return }
                    OfflineModeService.shared.prepareInitialServerErrorPresentation()
                    _ = await MusicLibraryStore.shared.prepareActiveServer(forceRefresh: true)
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await LibraryStore.shared.loadCachedStarred()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await LibraryStore.shared.loadAlbums()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision,
                          let currentServer = serverStore.activeServer,
                          currentServer.id == server.id
                    else { return }
                    await PlayLogService.shared.setup()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await DownloadDatabase.shared.setup()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await Task(priority: .utility) {
                        await RecapStore.shared.setup(serverId: currentServer.stableId)
                    }.value
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    // Artists vor setActiveServer laden: .libraryArtistsLoaded feuert → artistCoverByName
                    // in DownloadStore befüllt, bevor reload() DownloadedArtist-Objekte baut.
                    await LibraryStore.shared.loadArtists()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision,
                          let refreshedServer = serverStore.activeServer,
                          refreshedServer.id == server.id
                    else { return }
                    await LibraryStore.shared.loadPlaylists()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await DownloadStore.shared.setActiveServer(refreshedServer.stableId)
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    PinnedPlaylistStore.shared.setActiveServer(refreshedServer.stableId)
                    await LibraryStore.shared.loadStarred()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    let library = LibraryStore.shared
                    let estimatedAlbumCount = library.artists.reduce(0) {
                        $0 + max(0, $1.albumCount ?? 0)
                    }
                    SiriMediaAppSelectionService.shared.updateUserContext(
                        numberOfLibraryItems: estimatedAlbumCount
                            + library.artists.count
                            + library.starredSongs.count
                    )
                    // Nach App-Start / Server-Wechsel: auf eine fremde Remote-Queue prüfen.
                    await Task(priority: .utility) {
                        await QueueSyncService.shared.checkForRemoteQueue()
                    }.value
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await Task(priority: .utility) {
                        await BackgroundWorkCoordinator.shared.run(.keepLibraryOffline) {
                            await Self.runKeepLibraryOfflineCheck(serverId: refreshedServer.stableId)
                        }
                    }.value
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    ShelvAppShortcuts.updateAppShortcutParameters()
                }
                .task(priority: .utility) {
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
                    for server in serverStore.servers where server.remoteUserId == nil {
                        guard let pw = await serverStore.loadPassword(for: server) else { continue }
                        do {
                            let uid = try await SubsonicAPIService.shared.validatedStableId(
                                server: server,
                                password: pw
                            )
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
                .onChange(of: scenePhase) { _, phase in
                    updateIdleTimer(phase: phase)
                    guard phase == .active else { return }
                    ShelvAppShortcuts.updateAppShortcutParameters()
                    // syncNow prüft die Remote-Queue automatisch mit.
                    Task(priority: .utility) {
                        await BackgroundWorkCoordinator.shared.run(.cloudSync) {
                            await CloudKitSyncService.shared.syncNow()
                        }
                        guard !Task.isCancelled, let active = serverStore.activeServer else { return }
                        await BackgroundWorkCoordinator.shared.run(.keepLibraryOffline) {
                            await Self.runKeepLibraryOfflineCheck(serverId: active.stableId)
                        }
                    }
                }
                .onReceive(
                    downloadActivity.$batchProgress
                        .map { ($0?.remaining ?? 0) > 0 }
                        .removeDuplicates()
                ) { _ in
                    updateIdleTimer(phase: scenePhase)
                }
                .onChange(of: preventSleepDuringDownloads) { _, _ in
                    updateIdleTimer(phase: scenePhase)
                }
                .onChange(of: offlineMode.isOffline) { _, isOffline in
                    Task { @MainActor in
                        await LibraryStore.shared.loadCachedStarred()
                        if !isOffline {
                            await LibraryStore.shared.loadStarred()
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
                    guard let server = serverStore.activeServer else { return }
                    Task { await RecapStore.shared.loadEntries(serverId: server.stableId) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .musicLibrarySelectionChanged)) { notification in
                    guard let serverID = notification.object as? UUID,
                          serverStore.activeServer?.id == serverID
                    else { return }
                    musicLibraryReloadTask?.cancel()
                    musicLibraryReloadTask = Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled,
                              serverStore.activeServer?.id == serverID
                        else { return }
                        LibraryStore.shared.resetForMusicLibrarySelection()
                        await LibraryStore.shared.loadAlbums()
                        guard !Task.isCancelled else { return }
                        async let artists: Void = LibraryStore.shared.loadArtists()
                        async let starred: Void = LibraryStore.shared.loadStarred()
                        async let discover: Bool = LibraryStore.shared.loadDiscover()
                        _ = await (artists, starred, discover)
                    }
                }
        }
    }

    /// Verhindert das automatische Sperren des Bildschirms, solange der Toggle aktiv ist,
    /// Downloads laufen und die App im Vordergrund ist. Sobald eine dieser Bedingungen
    /// wegfällt (App in Background, Downloads fertig, Toggle aus), wird das normale
    /// Sperrverhalten wiederhergestellt.
    private func updateIdleTimer(phase: ScenePhase) {
        let hasRunningDownloads = (downloadActivity.batchProgress?.remaining ?? 0) > 0
        let shouldPrevent = preventSleepDuringDownloads
            && phase == .active
            && hasRunningDownloads
        UIApplication.shared.isIdleTimerDisabled = shouldPrevent
    }

    @MainActor
    private static func runKeepLibraryOfflineCheck(serverId: String, force: Bool = false) async {
        guard SubsonicAPIService.shared.activeServer?.stableId == serverId else { return }
        guard UserDefaults.standard.bool(forKey: "enableDownloads") else { return }
        guard KeepLibraryOfflineService.shared.isEnabled(serverId: serverId) else { return }
        await DownloadService.shared.waitForRestoredInflightTasks()
        guard SubsonicAPIService.shared.activeServer?.stableId == serverId else { return }
        await LibraryStore.shared.loadAlbums()
        guard SubsonicAPIService.shared.activeServer?.stableId == serverId else { return }
        let activeServer = SubsonicAPIService.shared.activeServer
        let selection = MusicLibraryStore.shared.snapshot
        let allLibraryAlbums: [Album]
        if let serverKey = activeServer?.id.uuidString {
            let cached = await LibraryRepository.shared.cachedAlbums(
                serverKey: serverKey,
                libraryIDs: selection.allCacheFolderIDs
            )
            allLibraryAlbums = cached.isEmpty ? LibraryStore.shared.albums : cached
        } else {
            allLibraryAlbums = LibraryStore.shared.albums
        }
        guard SubsonicAPIService.shared.activeServer?.stableId == serverId else { return }
        let recapIds = UserDefaults.standard.bool(forKey: "recapEnabled")
            ? Array(RecapStore.shared.recapPlaylistIds)
            : []
        let favorites = UserDefaults.standard.object(forKey: "enableFavorites") as? Bool ?? true
        await KeepLibraryOfflineService.shared.checkAndDownload(
            serverId: serverId,
            libraryAlbums: allLibraryAlbums,
            favorites: favorites,
            recapPlaylistIds: recapIds,
            force: force
        )
    }
}
