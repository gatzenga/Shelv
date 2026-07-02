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
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var searchResetToken = 0
    @State private var showPlayer = false
    @State private var showRecap = false
    @State private var showAddServer = false
    @State private var playlistSongIds: [String]? = nil
    @State private var offlineToast: ShelveToast?
    @State private var settingsPath = NavigationPath()
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsTab = true
    @AppStorage(PersonalizationPreferenceKey.miniPlayerStyle) private var miniPlayerStyleRaw = PersonalizationMiniPlayerStyle.shelv.rawValue

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var miniPlayerStyle: PersonalizationMiniPlayerStyle {
        PersonalizationMiniPlayerStyle(rawValue: miniPlayerStyleRaw) ?? .shelv
    }
    private var usesNativeMiniPlayer: Bool {
        guard miniPlayerStyle == .native else { return false }
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    var body: some View {
        rootContent
            .ignoresSafeArea(.keyboard)
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
                RadioStationStore.shared.resetInMemory()
                #if DEBUG
                // Demo-Server aktiv → festes Player-Standbild setzen (nach stop(), sonst würde
                // es sofort wieder gelöscht) und Recap-Anzeige aktivieren.
                if SubsonicAPIService.shared.isDemoActive {
                    AudioPlayerService.shared.ensureDemoStandby(force: true)
                }
                #endif
            }
            .onChange(of: showPlaylistsTab) { _, enabled in
                if !enabled && selectedTab == 2 { selectedTab = 0 }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                #if DEBUG
                AudioPlayerService.shared.ensureDemoStandby()
                #endif
                handlePendingShortcutDestination()
            }
            .onAppear {
                #if DEBUG
                if DemoContent.isLargeLibraryFixtureEnabled {
                    selectedTab = 1
                }
                AudioPlayerService.shared.ensureDemoStandby()
                #endif
                if serverStore.servers.isEmpty {
                    showAddServer = true
                }
                handlePendingShortcutDestination()
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if usesNativeMiniPlayer {
            NativeBottomRoot(
                tabSelection: tabSelection,
                searchResetToken: searchResetToken,
                settingsPath: $settingsPath,
                showPlayer: $showPlayer
            )
        } else {
            ShelvBottomRoot(
                tabSelection: tabSelection,
                searchResetToken: searchResetToken,
                settingsPath: $settingsPath,
                showPlayer: $showPlayer
            )
        }
    }

    /// Tab-Selection-Binding: Bei jedem Wechsel zum Search-Tab (Tag 4) wird der Reset-Token
    /// erhöht — SearchView leert daraufhin Eingabe + Ergebnisse und fokussiert die Suchleiste neu.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if newValue == 4 { searchResetToken += 1 }
                    selectedTab = newValue
                }
            }
        )
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
            if AudioPlayerService.shared.hasActivePlayback {
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

private struct ShelvBottomRoot: View {
    let tabSelection: Binding<Int>
    let searchResetToken: Int
    @Binding var settingsPath: NavigationPath
    @Binding var showPlayer: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsTab = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                standardTabView

                PlayerBarOverlay(
                    isRegularWidth: isRegularWidth,
                    safeAreaBottom: geometry.safeAreaInsets.bottom,
                    showPlayer: $showPlayer
                )
            }
            .wrappedInGlassContainer()
            .overlay(alignment: .top) {
                BottomBanners(topInset: geometry.safeAreaInsets.top)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBarInset(isRegularWidth: isRegularWidth, showPlayer: $showPlayer)
        }
    }

    private var standardTabView: some View {
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
            if showPlaylistsTab {
                PlaylistsView()
                    .tabItem { Label(String(localized: "playlists"), systemImage: "music.note.list") }
                    .tag(2)
            }
            SettingsView(path: $settingsPath)
                .tabItem { Label(String(localized: "settings"), systemImage: "gearshape.fill") }
                .tag(3)
            SearchView(resetToken: searchResetToken, searchPlacement: .automatic)
                .tabItem { Label(String(localized: "search"), systemImage: "magnifyingglass") }
                .tag(4)
        }
        .tint(accentColor)
    }
}

private struct NativeBottomRoot: View {
    let tabSelection: Binding<Int>
    let searchResetToken: Int
    @Binding var settingsPath: NavigationPath
    @Binding var showPlayer: Bool

    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @Environment(\.colorScheme) private var appColorScheme
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsTab = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var libraryTabTitle: String {
        if offlineMode.isOffline && enableDownloads {
            return String(localized: "downloads")
        }
        return String(localized: "library")
    }
    private var libraryTabImage: String {
        if offlineMode.isOffline && enableDownloads {
            return "arrow.down.circle.fill"
        }
        return "books.vertical.fill"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if #available(iOS 26.0, *) {
                    nativeTabView
                } else {
                    EmptyView()
                }
            }
            .overlay(alignment: .top) {
                BottomBanners(topInset: geometry.safeAreaInsets.top)
            }
        }
    }

    @available(iOS 26.0, *)
    private var tabs: some View {
        TabView(selection: tabSelection) {
            Tab(String(localized: "discover"), systemImage: "sparkles", value: 0) {
                DiscoverView()
            }
            Tab(libraryTabTitle, systemImage: libraryTabImage, value: 1) {
                LibraryView()
            }
            if showPlaylistsTab {
                Tab(String(localized: "playlists"), systemImage: "music.note.list", value: 2) {
                    PlaylistsView()
                }
            }
            Tab(String(localized: "settings"), systemImage: "gearshape.fill", value: 3) {
                SettingsView(path: $settingsPath)
            }
            Tab(value: 4, role: .search) {
                SearchView(resetToken: searchResetToken)
            }
        }
        .tabBarMinimizeBehavior(player.hasActivePlayback ? .onScrollDown : .automatic)
        .tabViewSearchActivation(.searchTabSelection)
        .tint(accentColor)
    }

    @available(iOS 26.0, *)
    @ViewBuilder
    private var nativeTabView: some View {
        if #available(iOS 26.1, *) {
            tabs
                .tabViewBottomAccessory(isEnabled: player.hasActivePlayback) {
                    NativeMiniPlayerAccessory(showPlayer: $showPlayer, appColorScheme: appColorScheme)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 2)
                }
        } else {
            tabs
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    NativeMiniPlayerAccessory(showPlayer: $showPlayer, appColorScheme: appColorScheme)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                }
        }
    }
}

private struct BottomBanners: View {
    let topInset: CGFloat

    @ObservedObject private var offlineMode = OfflineModeService.shared
    @ObservedObject private var queueSync = QueueSyncService.shared

    var body: some View {
        VStack(spacing: 8) {
            ServerErrorBanner()
                .animation(.easeInOut, value: offlineMode.serverErrorBannerVisible)
            QueueSyncBanner()
                .animation(.easeInOut, value: queueSync.pendingRemote != nil)
        }
        .padding(.top, topInset + 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(offlineMode.serverErrorBannerVisible || queueSync.pendingRemote != nil)
        .ignoresSafeArea(edges: .top)
    }
}

@available(iOS 26.0, *)
private struct NativeMiniPlayerAccessory: View {
    @Binding var showPlayer: Bool
    let appColorScheme: ColorScheme
    @ObservedObject private var player = AudioPlayerService.shared
    @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement
    @AppStorage("themeColor") private var themeColorName = "violet"
    @State private var dragX: CGFloat = 0

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    // Native tab accessories can use a contrasting glass color scheme; keep text tied to the app appearance.
    private var primaryAccessoryText: Color {
        appUsesDarkAppearance ? .white.opacity(0.92) : .black.opacity(0.90)
    }
    private var secondaryAccessoryText: Color {
        appUsesDarkAppearance ? .white.opacity(0.62) : .black.opacity(0.56)
    }
    private var appUsesDarkAppearance: Bool {
        appColorScheme == .dark
    }
    private var showsSkipButtons: Bool {
        accessoryPlacement != .inline
    }

    var body: some View {
        if player.hasActivePlayback {
            Button(action: presentPlayer) {
                HStack(spacing: 10) {
                    if let song = player.currentSong {
                        AlbumArtView(coverArtId: song.coverArt, size: 100, cornerRadius: 6)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else if let station = player.currentRadioStation {
                        RadioStationArtworkView(item: station, size: 32, metadata: player.currentRadioMetadata)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(primaryAccessoryText)
                            .lineLimit(1)
                        Text(player.displaySubtitleLine)
                            .font(.caption2)
                            .foregroundStyle(secondaryAccessoryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    playbackControls
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .offset(x: dragX)
                .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: dragX)
            }
            .buttonStyle(.plain)
            .highPriorityGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragX = value.translation.width / 2.2
                    }
                    .onEnded { value in
                        let width = value.translation.width
                        if abs(width) > abs(value.translation.height) {
                            guard !player.isRadioPlayback else {
                                dragX = 0
                                return
                            }
                            if width < -48 {
                                player.next(triggeredByUser: true)
                            } else if width > 48 {
                                player.previous()
                            }
                        }
                        dragX = 0
                    }
            )
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            if showsSkipButtons && !player.isRadioPlayback {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryAccessoryText)
                        .frame(width: 24, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "previous"))
            }

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(accentColor, in: Circle())
                    .frame(width: 34, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? String(localized: "pause") : String(localized: "play"))

            if showsSkipButtons && !player.isRadioPlayback {
                Button {
                    player.next(triggeredByUser: true)
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(player.hasNextTrack ? primaryAccessoryText : secondaryAccessoryText)
                        .frame(width: 24, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!player.hasNextTrack)
                .accessibilityLabel(String(localized: "next"))
            }
        }
    }

    private func presentPlayer() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            showPlayer = true
        }
    }
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
        if player.hasActivePlayback && !isRegularWidth {
            VStack {
                Spacer()
                PlayerBarView()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showPlayer = true
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, bottomOffset + 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
            .onAppear { scheduleMeasurements() }
            .onChange(of: player.currentSong?.id ?? player.currentRadioStation?.id) { _, _ in scheduleMeasurements() }
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
        if player.hasActivePlayback && isRegularWidth {
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
