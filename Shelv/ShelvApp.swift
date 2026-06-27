import AppIntents
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
    @StateObject private var serverStore = ServerStore()
    @ObservedObject private var downloadStore = DownloadStore.shared
    private let _playTracker = PlayTracker.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("preventSleepDuringDownloads") private var preventSleepDuringDownloads = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // AAC ist für Streaming nicht supported — Migration falls vorher gesetzt
        let d = UserDefaults.standard
        if d.string(forKey: "transcodingWifiCodec") == "aac" { d.set("raw", forKey: "transcodingWifiCodec") }
        if d.string(forKey: "transcodingCellularCodec") == "aac" { d.set("raw", forKey: "transcodingCellularCodec") }
        if d.string(forKey: "transcodingDownloadCodec") == "aac" { d.set("raw", forKey: "transcodingDownloadCodec") }
        UserDefaults.standard.register(defaults: [
            "recapWeeklyEnabled": true,
            "recapMonthlyEnabled": true,
            "recapYearlyEnabled": true,
            "enableDownloads": false,
            "offlineModeEnabled": false,
            "maxBulkDownloadStorageGB": 10,
            "transcodingEnabled": false,
            "transcodingWifiCodec": "raw",
            "transcodingWifiBitrate": 256,
            "transcodingCellularCodec": "raw",
            "transcodingCellularBitrate": 128,
            "transcodingDownloadCodec": "raw",
            "transcodingDownloadBitrate": 192,
        ])
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
                .environmentObject(serverStore)
                .environmentObject(LibraryStore.shared)
                .environmentObject(AudioPlayerService.shared)
                .environmentObject(LyricsStore.shared)
                .environmentObject(RecapStore.shared)
                .environmentObject(CloudKitSyncService.shared.status)
                .environmentObject(DownloadStore.shared)
                .environmentObject(OfflineModeService.shared)
                .tint(AppTheme.color(for: themeColorName))
                .preferredColorScheme(preferredScheme)
                .task {
                    ShelvAppShortcuts.updateAppShortcutParameters()
                    print("[Shortcuts] Parameters updated")
                    await LyricsStore.shared.setup()
                }
                .task(id: serverStore.activeServerID) {
                    guard let server = serverStore.activeServer else { return }
                    await PlayLogService.shared.setup()
                    await DownloadDatabase.shared.setup()
                    await RecapStore.shared.setup(serverId: server.stableId)
                    // Artists vor setActiveServer laden: .libraryArtistsLoaded feuert → artistCoverByName
                    // in DownloadStore befüllt, bevor reload() DownloadedArtist-Objekte baut.
                    await LibraryStore.shared.loadArtists()
                    await DownloadStore.shared.setActiveServer(server.stableId)
                    PinnedPlaylistStore.shared.setActiveServer(server.stableId)
                    await LibraryStore.shared.loadStarred()
                    // Nach App-Start / Server-Wechsel: auf eine fremde Remote-Queue prüfen.
                    await QueueSyncService.shared.checkForRemoteQueue()
                }
                .task {
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
                        guard let pw = serverStore.password(for: server) else { continue }
                        do {
                            let uid = try await SubsonicAPIService.shared.authLogin(server: server, password: pw)
                            var updated = server
                            updated.remoteUserId = uid
                            serverStore.update(server: updated, password: nil)
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
                    // syncNow prüft die Remote-Queue automatisch mit.
                    Task { await CloudKitSyncService.shared.syncNow() }
                }
                .onChange(of: downloadStore.batchProgress) { _, _ in
                    updateIdleTimer(phase: scenePhase)
                }
                .onChange(of: preventSleepDuringDownloads) { _, _ in
                    updateIdleTimer(phase: scenePhase)
                }
                .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
                    guard let server = serverStore.activeServer else { return }
                    Task { await RecapStore.shared.loadEntries(serverId: server.stableId) }
                }
        }
    }

    /// Verhindert das automatische Sperren des Bildschirms, solange der Toggle aktiv ist,
    /// Downloads laufen und die App im Vordergrund ist. Sobald eine dieser Bedingungen
    /// wegfällt (App in Background, Downloads fertig, Toggle aus), wird das normale
    /// Sperrverhalten wiederhergestellt.
    private func updateIdleTimer(phase: ScenePhase) {
        let hasRunningDownloads = (downloadStore.batchProgress?.remaining ?? 0) > 0
        let shouldPrevent = preventSleepDuringDownloads
            && phase == .active
            && hasRunningDownloads
        UIApplication.shared.isIdleTimerDisabled = shouldPrevent
    }
}
