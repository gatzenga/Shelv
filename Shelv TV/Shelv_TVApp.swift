import SwiftUI

@main
struct Shelv_TVApp: App {
    @StateObject private var serverStore = ServerStore()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("appAppearance") private var appAppearance = "system"

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
                .environmentObject(AudioPlayerService.shared)
                .environmentObject(RecapStore.shared)
                .environmentObject(CloudKitSyncService.shared.status)
                .preferredColorScheme(preferredScheme)
                // Pro aktivem Server: Tracking-DB + Recap-Registry (NUR laden, nie generieren) + Pins.
                .task(id: serverStore.activeServerID) {
                    guard let server = serverStore.activeServer else { return }
                    await PlayLogService.shared.setup()
                    await RecapStore.shared.loadEntries(serverId: server.stableId)
                    PinnedPlaylistStore.shared.setActiveServer(server.stableId)
                    // Favoriten + Künstler früh laden: Kontextmenüs zeigen den Stern-Status korrekt,
                    // und der Künstler-Link im Player kann den Künstler per Name auflösen.
                    await LibraryStore.shared.loadStarred()
                    await LibraryStore.shared.loadArtists()
                    await QueueSyncService.shared.checkForRemoteQueue()
                }
                // Einmaliges App-Setup: Tracking starten, remoteUserId-Backfill, iCloud-Sync.
                .task {
                    await PlayLogService.shared.setup()
                    _ = PlayTracker.shared   // startet Play-Erfassung (Combine-Observer)
                    for server in serverStore.servers where server.remoteUserId == nil {
                        guard let pw = serverStore.password(for: server) else { continue }
                        do {
                            let uid = try await SubsonicAPIService.shared.authLogin(server: server, password: pw)
                            var updated = server
                            updated.remoteUserId = uid
                            serverStore.update(server: updated, password: nil)
                        } catch {
                            print("[ServerID] Backfill FAILED \(server.displayName): \(error)")
                        }
                    }
                    await CloudKitSyncService.shared.setup()
                    // Beim Kaltstart deterministisch einmal synchronisieren — setup() allein lädt
                    // keine Remote-Plays; erst syncNow() ruft downloadChanges() und holt die Historie.
                    await CloudKitSyncService.shared.syncNow()
                }
                // Server-Wechsel: alten Stream stoppen (VOR dem Reset, sonst spielt der alte
                // Server weiter) und Library leeren → Views laden über reloadID neu. Wie iOS.
                .onChange(of: serverStore.activeServerID) { _, _ in
                    #if DEBUG
                    if SubsonicAPIService.shared.isDemoActive {
                        // Demo: kein stop() (kein echter alter Stream) — würde nur den festen
                        // Standby-Eintrag wieder wegwischen. Nur Standby setzen + Views neu laden.
                        AudioPlayerService.shared.loadDemoStandby()
                        LibraryStore.shared.resetInMemory()
                        UserDefaults.standard.set(true, forKey: "recapEnabled")
                        return
                    }
                    #endif
                    // Echter Server-Wechsel: alten Stream stoppen (VOR Reset) + Library leeren.
                    AudioPlayerService.shared.stop()
                    QueueSyncService.shared.handleServerChange()
                    LibraryStore.shared.resetInMemory()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // syncNow prüft die Remote-Queue automatisch mit.
                    Task { await CloudKitSyncService.shared.syncNow() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
                    guard let server = serverStore.activeServer else { return }
                    Task { await RecapStore.shared.loadEntries(serverId: server.stableId) }
                }
        }
    }
}
