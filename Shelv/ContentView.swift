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
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsTab = true
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
            FloatingBottomControls(
                selection: tabSelection,
                showPlaylistsTab: showPlaylistsTab,
                isRegularWidth: isRegularWidth,
                showPlayer: $showPlayer,
                accentColor: accentColor
            )
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
        .onChange(of: showPlaylistsTab) { _, enabled in
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
                if showPlaylistsTab {
                    PlaylistsView()
                        .tabItem { Label(String(localized: "playlists"), systemImage: "music.note.list") }
                        .tag(2)
                }
                SettingsView()
                    .tabItem { Label(String(localized: "settings"), systemImage: "gearshape.fill") }
                    .tag(3)
                SearchView(resetToken: searchResetToken)
                    .tabItem { Label(String(localized: "search"), systemImage: "magnifyingglass") }
                    .tag(4)
            }
            .tint(accentColor)
            .toolbar(.hidden, for: .tabBar)

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

private struct FloatingBottomControls: View {
    @Binding var selection: Int
    let showPlaylistsTab: Bool
    let isRegularWidth: Bool
    @Binding var showPlayer: Bool
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("enableDownloads") private var enableDownloads = false
    let accentColor: Color

    private var maxWidth: CGFloat {
        isRegularWidth ? 780 : .infinity
    }

    var body: some View {
        VStack(spacing: 10) {
            if player.currentSong != nil {
                PlayerBarView()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showPlayer = true
                        }
                    }
                    .padding(.horizontal, isRegularWidth ? 24 : 18)
                    .frame(maxWidth: isRegularWidth ? 760 : .infinity)
            }

            HStack(spacing: isRegularWidth ? 14 : 10) {
                FloatingMainTabBar(
                    tabs: tabs,
                    selection: $selection,
                    accentColor: accentColor
                )

                FloatingSearchButton(
                    isSelected: selection == 4,
                    accentColor: accentColor,
                    isRegularWidth: isRegularWidth
                ) {
                    selection = 4
                }
            }
            .frame(maxWidth: maxWidth)
            .padding(.horizontal, isRegularWidth ? 24 : 12)
        }
        .padding(.top, player.currentSong == nil ? 6 : 2)
        .padding(.bottom, 8)
    }

    private var tabs: [FloatingTabItem] {
        var items = [
            FloatingTabItem(tag: 0, titleKey: "home", systemImage: "house.fill"),
            FloatingTabItem(tag: 1, titleKey: libraryTitleKey, systemImage: librarySystemImage),
        ]
        if showPlaylistsTab {
            items.append(FloatingTabItem(tag: 2, titleKey: "playlists", systemImage: "music.note.list"))
        }
        items.append(FloatingTabItem(tag: 3, titleKey: "settings", systemImage: "gearshape.fill"))
        return items
    }

    private var libraryTitleKey: String {
        offlineMode.isOffline && enableDownloads ? "downloads" : "library"
    }

    private var librarySystemImage: String {
        offlineMode.isOffline && enableDownloads ? "arrow.down.circle.fill" : "books.vertical.fill"
    }
}

private struct FloatingTabItem: Identifiable {
    let tag: Int
    let titleKey: String
    let systemImage: String

    var id: Int { tag }
}

private struct FloatingMainTabBar: View {
    let tabs: [FloatingTabItem]
    @Binding var selection: Int
    let accentColor: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                FloatingTabButton(
                    tab: tab,
                    isSelected: selection == tab.tag,
                    accentColor: accentColor
                ) {
                    selection = tab.tag
                }
            }
        }
        .padding(6)
        .frame(height: 76)
        .floatingGlass(in: Capsule(style: .continuous))
    }
}

private struct FloatingTabButton: View {
    let tab: FloatingTabItem
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var selectedFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.34) : Color.white.opacity(0.70)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 25, weight: .semibold))
                    .frame(height: 27)
                Text(String(localized: String.LocalizationValue(tab.titleKey)))
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(isSelected ? accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.horizontal, 2)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(selectedFill)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: String.LocalizationValue(tab.titleKey))))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct FloatingSearchButton: View {
    let isSelected: Bool
    let accentColor: Color
    let isRegularWidth: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: isRegularWidth ? 34 : 32, weight: .semibold))
                .foregroundStyle(isSelected ? accentColor : Color.primary)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .floatingGlass(in: Circle())
        .accessibilityLabel(Text(String(localized: "search")))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var size: CGFloat {
        isRegularWidth ? 76 : 72
    }
}

private struct FloatingGlassBackground<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        }
    }
}

private extension View {
    func floatingGlass<S: Shape>(in shape: S) -> some View {
        modifier(FloatingGlassBackground(shape: shape))
    }
}
