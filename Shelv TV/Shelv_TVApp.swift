import SwiftUI

@main
struct Shelv_TVApp: App {
    @StateObject private var serverStore = ServerStore.shared
    private let _playTracker = PlayTracker.shared
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("appAppearance") private var appAppearance = "system"

    init() {
        PersonalizationSettings.registerDefaults()
        ShelvDefaultSettings.registerDefaults()
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
                .environmentObject(AudioPlayerService.shared)
                .environmentObject(RecapStore.shared)
                .environmentObject(CloudKitSyncService.shared.status)
                .preferredColorScheme(preferredScheme)
                // Pro aktivem Server: Tracking-DB + Recap-Registry (NUR laden, nie generieren) + Pins.
                .task(id: serverStore.activeServerRevision) {
                    await serverStore.waitUntilReady()
                    let revision = serverStore.activeServerRevision
                    await Task.yield()
                    guard revision == serverStore.activeServerRevision else { return }
                    LibraryStore.shared.resetInMemory()
                    guard let server = serverStore.activeServer else { return }
                    OfflineModeService.shared.prepareInitialServerErrorPresentation()
                    #if DEBUG
                    AudioPlayerService.shared.ensureDemoStandby()
                    #endif
                    await PlayLogService.shared.setup()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await RecapStore.shared.loadEntries(serverId: server.stableId)
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    PinnedPlaylistStore.shared.setActiveServer(server.stableId)
                    await LibraryStore.shared.loadAlbums()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision,
                          let currentServer = serverStore.activeServer,
                          currentServer.id == server.id
                    else { return }
                    // Favoriten + Künstler früh laden: Kontextmenüs zeigen den Stern-Status korrekt,
                    // und der Künstler-Link im Player kann den Künstler per Name auflösen.
                    await LibraryStore.shared.loadStarred()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await LibraryStore.shared.loadArtists()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision,
                          serverStore.activeServer?.id == currentServer.id
                    else { return }
                    await LibraryStore.shared.loadPlaylists()
                    guard !Task.isCancelled,
                          revision == serverStore.activeServerRevision
                    else { return }
                    await QueueSyncService.shared.checkForRemoteQueue()
                }
                // Einmaliges App-Setup: Tracking starten, remoteUserId-Backfill, iCloud-Sync.
                .task {
                    await serverStore.waitUntilReady()
                    await PlayLogService.shared.setup()
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
                        } catch {
                            print("[ServerID] Backfill FAILED \(server.displayName): \(error)")
                        }
                    }
                    await CloudKitSyncService.shared.setup()
                    // Beim Kaltstart deterministisch einmal synchronisieren — setup() allein lädt
                    // keine Remote-Plays; erst syncNow() ruft downloadChanges() und holt die Historie.
                    await CloudKitSyncService.shared.syncNow()
                }
                // Server-Wechsel: alten Stream stoppen; die revisionsgebundene Root-Task
                // ist der einzige Owner für Library-Reset und -Reload.
                .onChange(of: serverStore.activeServerID) { _, _ in
                    #if DEBUG
                    if SubsonicAPIService.shared.isDemoActive {
                        // Demo: kein stop() (kein echter alter Stream) — würde nur den festen
                        // Standby-Eintrag wieder wegwischen. Nur Standby setzen + Views neu laden.
                        AudioPlayerService.shared.ensureDemoStandby(force: true)
                        RadioStationStore.shared.resetInMemory()
                        return
                    }
                    #endif
                    // Echter Server-Wechsel: alten Stream stoppen; Library folgt der Revision.
                    AudioPlayerService.shared.stop()
                    QueueSyncService.shared.handleServerChange()
                    RadioStationStore.shared.resetInMemory()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    #if DEBUG
                    AudioPlayerService.shared.ensureDemoStandby()
                    #endif
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
