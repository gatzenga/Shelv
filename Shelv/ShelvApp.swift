import SwiftUI

let appLang: String = Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"

extension Notification.Name {
    nonisolated static let recapRegistryUpdated = Notification.Name("shelv.recapRegistryUpdated")
}

func tr(_ en: String, _ de: String, _ lang: String = appLang) -> String {
    lang == "de" ? de : en
}

@main
struct ShelvApp: App {
    @StateObject private var serverStore = ServerStore()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var player = AudioPlayerService.shared
    @StateObject private var lyricsStore = LyricsStore()
    @StateObject private var recapStore = RecapStore()
    @StateObject private var ckStatus = CloudKitSyncService.shared.status
    private let _playTracker = PlayTracker.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("appAppearance") private var appAppearance = "system"
    @Environment(\.scenePhase) private var scenePhase

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
                .tint(AppTheme.color(for: themeColorName))
                .preferredColorScheme(preferredScheme)
                .task { await lyricsStore.setup() }
                .task(id: serverStore.activeServerID) {
                    guard let server = serverStore.activeServer else { return }
                    await recapStore.setup(serverId: server.stableId)
                }
                .task {
                    await PlayLogService.shared.setup()
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
