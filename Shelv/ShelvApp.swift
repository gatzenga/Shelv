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
                .task { await LyricsStore.shared.setup() }
                .task(id: serverStore.activeServerID) {
                    guard let server = serverStore.activeServer else { return }
                    await PlayLogService.shared.setup()
                    await DownloadDatabase.shared.setup()
                    await RecapStore.shared.setup(serverId: server.stableId)
                    await DownloadStore.shared.setActiveServer(server.stableId)
                }
                .task {
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
                    guard phase == .active else { return }
                    Task { await CloudKitSyncService.shared.syncNow() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
                    guard let server = serverStore.activeServer else { return }
                    Task { await RecapStore.shared.loadEntries(serverId: server.stableId) }
                }
        }
    }
}
