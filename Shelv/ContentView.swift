import SwiftUI

extension Notification.Name {
    static let addSongsToPlaylist = Notification.Name("addSongsToPlaylist")
    static let offlinePlaybackBlocked = Notification.Name("shelv.offlinePlaybackBlocked")
}

struct ContentView: View {
    @EnvironmentObject var serverStore: ServerStore
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var queueSync = QueueSyncService.shared
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var searchResetToken = 0
    @State private var showPlayer = false
    @State private var showRecap = false
    @State private var showAddServer = false
    @State private var playlistSongIds: [String]? = nil
    @State private var offlineToast: ShelveToast?
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        GeometryReader { geometry in
            mainStack(geometry: geometry)
                .wrappedInGlassContainer()
        }
        .ignoresSafeArea(.keyboard)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBarInset(isRegularWidth: isRegularWidth, showPlayer: $showPlayer)
        }
        .onChange(of: libraryStore.errorMessage) { _, msg in
            guard let msg else { return }
            libraryStore.errorMessage = nil
            offlineMode.notifyServerError(msg)
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDetents([.large])
                .presentationSizing(.page)
                .presentationBackgroundInteraction(.enabled)
                .presentationCornerRadius(24)
                .presentationDragIndicator(.visible)
                .tint(accentColor)
        }
        .sheet(isPresented: $showRecap) {
            RecapView()
                .environmentObject(serverStore)
                .presentationDetents([.large])
                .presentationCornerRadius(24)
                .tint(accentColor)
        }
        .sheet(isPresented: $showAddServer) {
            AddServerView()
                .environmentObject(serverStore)
                .tint(accentColor)
        }
        .sheet(item: Binding(
            get: { playlistSongIds.map { IdentifiableStrings(ids: $0) } },
            set: { if $0 == nil { playlistSongIds = nil } }
        )) { wrapper in
            AddToPlaylistSheet(songIds: wrapper.ids)
                .environmentObject(libraryStore)
                .tint(accentColor)
        }
        .onReceive(NotificationCenter.default.publisher(for: .addSongsToPlaylist)) { note in
            if let ids = note.object as? [String] {
                playlistSongIds = ids
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlinePlaybackBlocked)) { _ in
            offlineToast = ShelveToast(message: String(localized: "not_available_offline"), isError: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .instantMixUnavailable)) { _ in
            offlineToast = ShelveToast(message: String(localized: "no_instant_mix_available"), isError: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelvShortcutDestinationRequested)) { note in
            guard let rawValue = note.object as? String,
                  let destination = ShelvShortcutDestination(rawValue: rawValue)
            else {
                handlePendingShortcutDestination()
                return
            }
            handleShortcutDestination(destination)
        }
        .shelveToast($offlineToast)
        .onChange(of: serverStore.activeServerID) { _, _ in
            AudioPlayerService.shared.stop()
            QueueSyncService.shared.handleServerChange()
            libraryStore.resetInMemory()
            #if DEBUG
            // Demo-Server aktiv → festes Player-Standbild setzen (nach stop(), sonst würde
            // es sofort wieder gelöscht) und Recap-Anzeige aktivieren.
            if SubsonicAPIService.shared.isDemoActive {
                AudioPlayerService.shared.loadDemoStandby()
                UserDefaults.standard.set(true, forKey: "recapEnabled")
            }
            #endif
        }
        .onChange(of: enablePlaylists) { _, enabled in
            if !enabled && selectedTab == 2 { selectedTab = 0 }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            handlePendingShortcutDestination()
        }
        .onAppear {
            #if DEBUG
            if DemoContent.isLargeLibraryFixtureEnabled {
                selectedTab = 1
            }
            #endif
            if serverStore.servers.isEmpty {
                showAddServer = true
            }
            handlePendingShortcutDestination()
        }
    }

    /// Tab-Selection-Binding: Bei jedem Wechsel zum Search-Tab (Tag 4) wird der Reset-Token
    /// erhöht — SearchView leert daraufhin Eingabe + Ergebnisse und fokussiert die Suchleiste neu.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == 4 { searchResetToken += 1 }
                selectedTab = newValue
            }
        )
    }

    @ViewBuilder
    private func mainStack(geometry: GeometryProxy) -> some View {
        ZStack {
            TabView(selection: tabSelection) {
                DiscoverView()
                    .tabItem { Label(String(localized: "discover"), systemImage: "sparkles") }
                    .tag(0)
                LibraryView()
                    .tabItem {
                        if offlineMode.isOffline && enableDownloads {
                            Label(String(localized: "downloads"), systemImage: "arrow.down.circle.fill")
                        } else {
                            Label(String(localized: "library"), systemImage: "books.vertical.fill")
                        }
                    }
                    .tag(1)
                if enablePlaylists {
                    PlaylistsView()
                        .tabItem { Label(String(localized: "playlists"), systemImage: "music.note.list") }
                        .tag(2)
                }
                SearchView(resetToken: searchResetToken)
                    .tabItem { Label(String(localized: "search"), systemImage: "magnifyingglass") }
                    .tag(4)
                SettingsView()
                    .tabItem { Label(String(localized: "settings"), systemImage: "gearshape.fill") }
                    .tag(3)
            }
            .tint(accentColor)

            PlayerBarOverlay(
                isRegularWidth: isRegularWidth,
                safeAreaBottom: geometry.safeAreaInsets.bottom,
                showPlayer: $showPlayer
            )

            VStack {
                ServerErrorBanner()
                    .padding(.top, geometry.safeAreaInsets.top + 4)
                    .animation(.easeInOut, value: offlineMode.serverErrorBannerVisible)
                QueueSyncBanner()
                    .padding(.top, offlineMode.serverErrorBannerVisible ? 0 : geometry.safeAreaInsets.top + 4)
                    .animation(.easeInOut, value: queueSync.pendingRemote != nil)
                Spacer()
            }
            .allowsHitTesting(offlineMode.serverErrorBannerVisible || queueSync.pendingRemote != nil)
            .ignoresSafeArea(edges: .top)
        }
    }

    private func handlePendingShortcutDestination() {
        guard let destination = ShelvShortcutHandoff.consumePendingDestination() else { return }
        handleShortcutDestination(destination)
    }

    private func handleShortcutDestination(_ destination: ShelvShortcutDestination) {
        switch destination {
        case .discover:
            selectedTab = 0
        case .library:
            selectedTab = 1
        case .search:
            searchResetToken += 1
            selectedTab = 4
        case .recap:
            selectedTab = 0
            showRecap = true
        case .nowPlaying:
            if AudioPlayerService.shared.currentSong != nil {
                showPlayer = true
            } else {
                selectedTab = 0
            }
        }
    }
}

private extension View {
    /// Wraps the view in a `GlassEffectContainer` on iOS 26+ so multiple `.glassEffect()`-Views
    /// (Tab-Bar + Player) im selben Glas-System rendern und sich gegenseitig beeinflussen.
    @ViewBuilder
    func wrappedInGlassContainer() -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
    }
}

private struct IdentifiableStrings: Identifiable {
    var id: String { ids.joined(separator: ",") }
    let ids: [String]
}

/// Isoliertes PlayerBar-Overlay für iPhone — liest die echte Y-Position der Tab-Bar im Window,
/// damit der Player IMMER mit gleichem Abstand zur Tab-Bar sitzt, egal ob die Tab-Bar am Rand
/// klebt oder (wie in iOS 26 mit "Liquid Glass") schwebt.
private struct PlayerBarOverlay: View {
    let isRegularWidth: Bool
    let safeAreaBottom: CGFloat
    @Binding var showPlayer: Bool
    @ObservedObject private var player = AudioPlayerService.shared
    @State private var measuredOffset: CGFloat? = nil

    /// Initialer Schätzwert basiert auf safeArea: Home-Indicator (>20pt) → modernes iPhone (83pt),
    /// sonst SE-Style (49pt). Wird durch echte UIKit-Messung sofort ersetzt, sobald verfügbar.
    private var bottomOffset: CGFloat {
        measuredOffset ?? (safeAreaBottom > 20 ? 83 : 49)
    }

    var body: some View {
        if player.currentSong != nil && !isRegularWidth {
            VStack {
                Spacer()
                PlayerBarView()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showPlayer = true
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, bottomOffset + 3.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
            .onAppear { scheduleMeasurements() }
            .onChange(of: player.currentSong?.id) { _, _ in scheduleMeasurements() }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { measureTabBar() }
            }
        }
    }

    /// Startet die Messung sofort und wiederholt sie mit Verzögerungen, falls UIKit beim
    /// ersten Versuch noch nicht fertig layoutet ist (typisch bei App-Cold-Start mit Player).
    private func scheduleMeasurements() {
        measureTabBar()
        DispatchQueue.main.async { measureTabBar() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { measureTabBar() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { measureTabBar() }
    }

    /// Misst die Distanz vom unteren Bildschirmrand bis zur Oberkante der Tab-Bar.
    /// Funktioniert sowohl bei klassischen Tab-Bars (kleben am Rand) als auch bei
    /// schwebenden Tab-Bars (iOS 26 Liquid Glass mit eigenem Bottom-Margin).
    private func measureTabBar() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow })
                ?? scene?.windows.first(where: { !$0.isHidden })
                ?? scene?.windows.first,
              let tabBar = findTabBar(in: window.rootViewController)
                ?? findTabBarInViews(window)
        else { return }

        let frameInWindow = tabBar.convert(tabBar.bounds, to: window)
        let distance = window.bounds.height - frameInWindow.minY
        if distance > 0 { measuredOffset = distance }
    }

    private func findTabBar(in vc: UIViewController?) -> UITabBar? {
        guard let vc else { return nil }
        if let tbc = vc as? UITabBarController { return tbc.tabBar }
        return vc.children.lazy.compactMap { findTabBar(in: $0) }.first
    }

    private func findTabBarInViews(_ view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar { return tabBar }
        return view.subviews.lazy.compactMap { findTabBarInViews($0) }.first
    }
}

/// Isoliertes PlayerBar-Inset für iPad
private struct PlayerBarInset: View {
    let isRegularWidth: Bool
    @Binding var showPlayer: Bool
    @ObservedObject private var player = AudioPlayerService.shared

    var body: some View {
        if player.currentSong != nil && isRegularWidth {
            PlayerBarView()
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showPlayer = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }
}
