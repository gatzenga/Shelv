import SwiftUI

/// Tab-Gerüst der tvOS-App: Now Playing · Discover · Library · Playlists · Radio · Suche · Settings.
/// Nutzt die neue `Tab`-API (tvOS 18+) mit value-basierter Selection — die Legacy-
/// tabItem-API hatte auf tvOS kaputtes Menü-/Fokus-Verhalten (Tab-Bar unerreichbar,
/// leerer Tab nach Feature-Toggle).
struct MainTabView: View {
    private static let nowPlayingTab = "nowplaying"
    private static let discoverTab = "discover"
    private static let idleNowPlayingDelay: Duration = .seconds(10)

    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsTab = true
    @AppStorage(PersonalizationPreferenceKey.showRadio) private var showRadio = true
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @ObservedObject private var queueSync = QueueSyncService.shared
    @State private var selection = MainTabView.initialSelection
    @State private var visibleShowPlaylistsTab = MainTabView.initialBoolPreference(
        PersonalizationPreferenceKey.showPlaylistsTab,
        default: true
    )
    @State private var visibleShowRadio = MainTabView.initialRadioVisible
    @State private var showIdleNowPlaying = false
    @State private var nowPlayingSidePanel: TVNowPlayingPanel?
    @State private var nowPlayingRootVisible = false
    @State private var idleNowPlayingTask: Task<Void, Never>?

    private var serverErrorAlertTitle: String {
        if offlineMode.lastServerErrorWasDeviceOffline {
            return String(localized: "you_are_offline")
        }
        return String(localized: "server_unreachable")
    }

    private static var initialSelection: String {
        #if DEBUG
        if DemoContent.isLargeLibraryFixtureEnabled {
            return "library"
        }
        #endif
        return discoverTab
    }

    private static func initialBoolPreference(_ key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static var initialRadioVisible: Bool {
        guard !OfflineModeService.shared.isOffline else { return false }
        return initialBoolPreference(PersonalizationPreferenceKey.showRadio, default: true)
    }

    var body: some View {
        ZStack {
            tabView

            if showIdleNowPlaying {
                TVIdleNowPlayingView(panel: nowPlayingSidePanel) {
                    dismissIdleNowPlaying()
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showIdleNowPlaying)
        .simultaneousGesture(TapGesture().onEnded {
            registerUserActivity()
        })
        .onMoveCommand { _ in
            registerUserActivity()
        }
        .onExitCommand {
            if showIdleNowPlaying {
                dismissIdleNowPlaying()
            }
        }
        .onPlayPauseCommand {
            if showIdleNowPlaying {
                player.togglePlayPause()
            } else {
                registerUserActivity()
                player.togglePlayPause()
            }
        }
        .onChange(of: showPlaylistsTab) { _, _ in
            syncVisibleTabsIfAllowed()
        }
        .onChange(of: showRadio) { _, _ in
            syncVisibleTabsIfAllowed()
        }
        .onChange(of: offlineMode.isOffline) { _, _ in
            syncVisibleTabs()
        }
        .onChange(of: selection) { _, newSelection in
            if newSelection != "settings" {
                syncVisibleTabs()
            }
            updateIdleNowPlayingAvailability()
        }
        .onChange(of: visibleShowPlaylistsTab) { _, on in
            if !on && selection == "playlists" { selection = "settings" }
        }
        .onChange(of: visibleShowRadio) { _, on in
            if !on && selection == "radio" { selection = "search" }
        }
        .onChange(of: player.isPlaying) { _, _ in
            updateIdleNowPlayingAvailability()
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            updateIdleNowPlayingAvailability()
        }
        .onChange(of: player.currentRadioStation?.id) { _, _ in
            updateIdleNowPlayingAvailability()
        }
        .onChange(of: nowPlayingSidePanel) { _, _ in
            updateIdleNowPlayingAvailability()
        }
        .onChange(of: nowPlayingRootVisible) { _, _ in
            updateIdleNowPlayingAvailability()
        }
        // Fremde Queue von einem anderen Gerät — auf tvOS als nativer Alert (zuverlässig
        // fokussierbar, im Gegensatz zu einem Custom-Top-Banner). Nie automatisch.
        .alert(String(localized: "queue_available_title"), isPresented: Binding(
            get: { queueSync.pendingRemote != nil },
            set: { if !$0 { queueSync.dismissPending() } }
        )) {
            Button(String(localized: "queue_take_over")) { queueSync.acceptPending() }
            Button(String(localized: "cancel"), role: .cancel) { queueSync.dismissPending() }
        } message: {
            Text(String(localized: "queue_available_subtitle"))
        }
        .task(id: queueSync.pendingRemote?.signature) {
            guard let pendingSignature = queueSync.pendingRemote?.signature else { return }
            try? await Task.sleep(for: .seconds(6))
            guard queueSync.pendingRemote?.signature == pendingSignature else { return }
            queueSync.dismissPending()
        }
        .alert(serverErrorAlertTitle, isPresented: Binding(
            get: { offlineMode.serverErrorBannerVisible },
            set: { if !$0 { offlineMode.dismissBanner() } }
        )) {
            if offlineMode.downloadsFeatureEnabled {
                Button(String(localized: "go_offline")) {
                    offlineMode.enterOfflineMode()
                }
            }
            Button(String(localized: "ok"), role: .cancel) {
                offlineMode.dismissBanner()
            }
        } message: {
            Text(offlineMode.lastServerErrorMessage ?? String(localized: "switch_to_offline_mode_to_use_your_downloads"))
        }
        .onAppear {
            scheduleIdleNowPlayingIfNeeded()
        }
        .onDisappear {
            idleNowPlayingTask?.cancel()
        }
    }

    private var tabView: some View {
        TabView(selection: $selection) {
            Tab(String(localized: "now_playing"), systemImage: "play.circle", value: Self.nowPlayingTab) {
                NowPlayingView(
                    activeSidePanel: $nowPlayingSidePanel,
                    isRootVisible: $nowPlayingRootVisible
                )
            }

            Tab(String(localized: "discover"), systemImage: "sparkles", value: Self.discoverTab) {
                DiscoverView()
            }

            Tab(String(localized: "library"), systemImage: "square.stack", value: "library") {
                LibraryView()
            }

            if visibleShowPlaylistsTab {
                Tab(String(localized: "playlists"), systemImage: "music.note.list", value: "playlists") {
                    PlaylistsView()
                }
            }

            if visibleShowRadio {
                Tab(String(localized: "radio"), systemImage: "dot.radiowaves.left.and.right", value: "radio") {
                    RadioView()
                }
            }

            Tab(String(localized: "search"), systemImage: "magnifyingglass", value: "search") {
                SearchView()
            }

            Tab(String(localized: "settings"), systemImage: "gearshape", value: "settings") {
                SettingsView()
            }
        }
    }

    private func syncVisibleTabsIfAllowed() {
        guard selection != "settings" else { return }
        syncVisibleTabs()
    }

    private func syncVisibleTabs() {
        visibleShowPlaylistsTab = showPlaylistsTab
        visibleShowRadio = showRadio && !offlineMode.isOffline
    }

    private var canShowIdleNowPlaying: Bool {
        selection == Self.nowPlayingTab
            && nowPlayingRootVisible
            && player.hasActivePlayback
            && player.isPlaying
    }

    private var canKeepIdleNowPlayingVisible: Bool {
        selection == Self.nowPlayingTab
            && nowPlayingRootVisible
            && player.hasActivePlayback
    }

    private func registerUserActivity() {
        if showIdleNowPlaying {
            dismissIdleNowPlaying()
        } else {
            scheduleIdleNowPlayingIfNeeded()
        }
    }

    private func dismissIdleNowPlaying() {
        showIdleNowPlaying = false
        scheduleIdleNowPlayingIfNeeded()
    }

    private func updateIdleNowPlayingAvailability() {
        if showIdleNowPlaying {
            if canKeepIdleNowPlayingVisible {
                idleNowPlayingTask?.cancel()
            } else {
                showIdleNowPlaying = false
                idleNowPlayingTask?.cancel()
            }
        } else if canShowIdleNowPlaying {
            scheduleIdleNowPlayingIfNeeded()
        } else {
            showIdleNowPlaying = false
            idleNowPlayingTask?.cancel()
        }
    }

    private func scheduleIdleNowPlayingIfNeeded() {
        idleNowPlayingTask?.cancel()
        guard canShowIdleNowPlaying else {
            showIdleNowPlaying = false
            return
        }
        idleNowPlayingTask = Task {
            try? await Task.sleep(for: Self.idleNowPlayingDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if canShowIdleNowPlaying {
                    showIdleNowPlaying = true
                }
            }
        }
    }
}

private struct TVIdleNowPlayingView: View {
    let panel: TVNowPlayingPanel?
    let onDismiss: () -> Void

    @ObservedObject private var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColor = "violet"
    @FocusState private var isFocused: Bool
    @State private var displayTime: Double = 0
    @State private var displayDuration: Double = 0

    private var accent: Color { AppTheme.color(for: themeColor) }

    var body: some View {
        ZStack {
            background

            if panel == .lyrics, !player.isRadioPlayback {
                HStack(alignment: .center, spacing: 64) {
                    VStack(alignment: .center, spacing: 34) {
                        artwork
                        VStack(alignment: .leading, spacing: 24) {
                            metadata
                            progress
                        }
                        .frame(width: 560, alignment: .leading)
                    }
                    .frame(width: 620)

                    LyricsView()
                        .frame(width: 840, height: 840)
                }
                .frame(maxWidth: 1700, maxHeight: .infinity)
                .padding(.horizontal, 70)
            } else {
                HStack(alignment: .center, spacing: 86) {
                    artwork

                    VStack(alignment: .leading, spacing: 28) {
                        metadata
                        progress
                    }
                    .frame(width: 700, alignment: .leading)
                }
                .frame(maxWidth: 1500, maxHeight: .infinity)
                .padding(.horizontal, 90)
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            syncDisplayFromPlayer()
        }
        .onReceive(player.timePublisher) { t in
            displayTime = t.time
            displayDuration = t.duration
        }
        .onTapGesture(perform: onDismiss)
        .onMoveCommand { _ in onDismiss() }
        .onExitCommand(perform: onDismiss)
    }

    @ViewBuilder
    private var background: some View {
        TVPlayerGradientBackground(style: .idle)
    }

    @ViewBuilder
    private var artwork: some View {
        if let station = player.currentRadioStation {
            TVRadioStationArtworkView(item: station, size: 560, metadata: player.currentRadioMetadata)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        } else {
            CoverArtView(url: player.currentSong?.coverURL(900), size: 560, cornerRadius: 28)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.displayTitle)
                .font(.title2.bold())
                .lineLimit(1)
                .foregroundStyle(.primary)

            if let artist = currentArtist {
                Text(artist)
                    .font(.body)
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .lineLimit(1)
            }

            if let subtitle = currentSubtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Color.primary.opacity(0.60))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if player.isRadioPlayback {
            HStack(spacing: 12) {
                Circle()
                    .fill(player.isRadioConnecting ? .orange : .green)
                    .frame(width: 10, height: 10)
                Text(player.radioStatusText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 10) {
                TVIdleProgressBar(
                    progress: displayDuration > 0 ? min(max(displayTime / displayDuration, 0), 1) : 0
                )
                .frame(width: 620, height: 8)

                HStack {
                    Text(formatDuration(Int(displayTime)))
                    Spacer()
                    Text(formatDuration(Int(displayDuration)))
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 620)
            }
        }
    }

    private var currentArtist: String? {
        if player.isRadioPlayback {
            return player.radioDisplayArtist.isEmpty ? nil : player.radioDisplayArtist
        }
        return player.currentSong?.displayArtist ?? player.currentSong?.artist
    }

    private var currentSubtitle: String? {
        if player.isRadioPlayback {
            return player.radioDisplayStationName
        }
        return player.currentSong?.album
    }

    private func syncDisplayFromPlayer() {
        displayTime = player.currentTime
        displayDuration = player.duration
    }
}

private struct TVIdleProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))

                if progress > 0 {
                    Capsule()
                        .fill(.white.opacity(0.95))
                        .frame(width: proxy.size.width * progress)
                }
            }
        }
        .accessibilityElement(children: .ignore)
    }
}
