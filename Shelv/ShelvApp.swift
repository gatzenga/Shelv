import SwiftUI

let appLang: String = Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"

extension Notification.Name {
    nonisolated static let recapRegistryUpdated = Notification.Name("shelv.recapRegistryUpdated")
}

final class BackgroundDownloadHandler {
    static let shared = BackgroundDownloadHandler()
    var completionHandler: (() -> Void)?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloadHandler.shared.completionHandler = completionHandler
    }
}

func tr(_ en: String, _ de: String, _ lang: String = appLang) -> String {
    lang == "de" ? de : en
}

@main
struct ShelvApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serverStore = ServerStore()
    @StateObject private var libraryStore = LibraryStore.shared
    @StateObject private var player = AudioPlayerService.shared
    @StateObject private var lyricsStore = LyricsStore()
    @StateObject private var recapStore = RecapStore.shared
    @StateObject private var ckStatus = CloudKitSyncService.shared.status
    @StateObject private var downloadStore = DownloadStore.shared
    @StateObject private var offlineMode = OfflineModeService.shared
    private let _playTracker = PlayTracker.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("appAppearance") private var appAppearance = "system"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // AAC ist für Streaming nicht supported — Migration falls vorher gesetzt
        let d = UserDefaults.standard
        if d.string(forKey: "transcodingWifiCodec") == "aac" { d.set("raw", forKey: "transcodingWifiCodec") }
        if d.string(forKey: "transcodingCellularCodec") == "aac" { d.set("raw", forKey: "transcodingCellularCodec") }
        if d.string(forKey: "transcodingDownloadCodec") == "aac" { d.set("raw", forKey: "transcodingDownloadCodec") }
        // Gapless und Crossfade schliessen sich gegenseitig aus — unmöglichen Zustand korrigieren
        if d.bool(forKey: "gaplessEnabled") && d.bool(forKey: "crossfadeEnabled") {
            d.set(false, forKey: "crossfadeEnabled")
        }
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
                .environmentObject(libraryStore)
                .environmentObject(player)
                .environmentObject(lyricsStore)
                .environmentObject(recapStore)
                .environmentObject(ckStatus)
                .environmentObject(downloadStore)
                .environmentObject(offlineMode)
                .tint(AppTheme.color(for: themeColorName))
                .preferredColorScheme(preferredScheme)
                .task { await lyricsStore.setup() }
                .task(id: serverStore.activeServerID) {
                    guard let server = serverStore.activeServer else { return }
                    await PlayLogService.shared.setup()
                    await DownloadDatabase.shared.setup()
                    await recapStore.setup(serverId: server.stableId)
                    await downloadStore.setActiveServer(server.stableId)
                }
                .task {
                    await PlayLogService.shared.setup()
                    await DownloadDatabase.shared.setup()
                    await DownloadService.shared.setup()
                    if let active = serverStore.activeServer {
                        await downloadStore.setActiveServer(active.stableId)
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
                    guard phase == .active else { return }
                    Task { await CloudKitSyncService.shared.syncNow() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
                    guard let server = serverStore.activeServer else { return }
                    Task { await recapStore.loadEntries(serverId: server.stableId) }
                }
        }
    }
}
