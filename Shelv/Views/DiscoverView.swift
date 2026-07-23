import AVFoundation
import Combine
import SwiftUI
import UIKit

private struct DiscoverLibrarySnapshot: Equatable {
    var recentlyAdded: [Album]
    var recentlyPlayed: [Album]
    var frequentlyPlayed: [Album]
    var randomAlbums: [Album]
    var isLoadingDiscover: Bool
    var reloadID: UUID

    init(store: LibraryStore) {
        recentlyAdded = store.recentlyAdded
        recentlyPlayed = store.recentlyPlayed
        frequentlyPlayed = store.frequentlyPlayed
        randomAlbums = store.randomAlbums
        isLoadingDiscover = store.isLoadingDiscover
        reloadID = store.reloadID
    }
}

@MainActor
private final class DiscoverContentObserver: ObservableObject {
    @Published private(set) var library: DiscoverLibrarySnapshot
    @Published private(set) var recapPlaylistIDs: Set<String>

    private let libraryStore: LibraryStore
    private let recapStore: RecapStore
    private var isActive: Bool
    private var cancellables: Set<AnyCancellable> = []

    init(isActive: Bool) {
        let libraryStore = LibraryStore.shared
        let recapStore = RecapStore.shared
        self.isActive = isActive
        self.libraryStore = libraryStore
        self.recapStore = recapStore
        library = DiscoverLibrarySnapshot(store: libraryStore)
        recapPlaylistIDs = recapStore.recapPlaylistIds
        subscribeToRelevantChanges()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else {
            if active { synchronize() }
            return
        }
        isActive = active
        if active { synchronize() }
    }

    private func subscribeToRelevantChanges() {
        libraryStore.$recentlyAdded
            .removeDuplicates()
            .sink { [weak self] value in self?.update(\.recentlyAdded, to: value) }
            .store(in: &cancellables)
        libraryStore.$recentlyPlayed
            .removeDuplicates()
            .sink { [weak self] value in self?.update(\.recentlyPlayed, to: value) }
            .store(in: &cancellables)
        libraryStore.$frequentlyPlayed
            .removeDuplicates()
            .sink { [weak self] value in self?.update(\.frequentlyPlayed, to: value) }
            .store(in: &cancellables)
        libraryStore.$randomAlbums
            .removeDuplicates()
            .sink { [weak self] value in self?.update(\.randomAlbums, to: value) }
            .store(in: &cancellables)
        libraryStore.$isLoadingDiscover
            .removeDuplicates()
            .sink { [weak self] value in self?.update(\.isLoadingDiscover, to: value) }
            .store(in: &cancellables)
        libraryStore.$reloadID
            .removeDuplicates()
            .sink { [weak self] value in self?.update(\.reloadID, to: value) }
            .store(in: &cancellables)
        recapStore.$recapPlaylistIds
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self, isActive, recapPlaylistIDs != value else { return }
                recapPlaylistIDs = value
            }
            .store(in: &cancellables)
    }

    private func update<Value: Equatable>(
        _ keyPath: WritableKeyPath<DiscoverLibrarySnapshot, Value>,
        to value: Value
    ) {
        guard isActive, library[keyPath: keyPath] != value else { return }
        var updated = library
        updated[keyPath: keyPath] = value
        library = updated
    }

    private func synchronize() {
        let currentLibrary = DiscoverLibrarySnapshot(store: libraryStore)
        if library != currentLibrary {
            library = currentLibrary
        }
        let currentRecapPlaylistIDs = recapStore.recapPlaylistIds
        if recapPlaylistIDs != currentRecapPlaylistIDs {
            recapPlaylistIDs = currentRecapPlaylistIDs
        }
    }
}

struct DiscoverView: View {
    let isActive: Bool
    private let libraryStore = LibraryStore.shared
    @StateObject private var contentObserver: DiscoverContentObserver
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject private var musicLibraries = MusicLibraryStore.shared
    private let downloadStore = DownloadStore.shared
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.personalizationSwipeConfiguration) private var personalization
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage(PersonalizationPreferenceKey.showRadio) private var showRadio = true
    @AppStorage(PersonalizationPreferenceKey.showDiscoverInsights) private var showDiscoverInsights = true
    @AppStorage(PersonalizationPreferenceKey.showDiscoverAirPlay) private var showDiscoverAirPlay = false
    @AppStorage(PersonalizationPreferenceKey.showSmartMixNewest) private var showSmartMixNewest = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixFrequent) private var showSmartMixFrequent = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixRecent) private var showSmartMixRecent = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixRandom) private var showSmartMixRandom = true
    @AppStorage(PersonalizationPreferenceKey.discoverySectionOrder) private var discoverySectionOrderRaw = PersonalizationSettings.defaultDiscoverySectionOrderRaw
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    init(isActive: Bool = true) {
        self.isActive = isActive
        _contentObserver = StateObject(
            wrappedValue: DiscoverContentObserver(isActive: isActive)
        )
    }

    private var recapButtonVisible: Bool {
        // Wenn Recap deaktiviert ist, soll der Eintrag komplett aus der UI verschwinden.
        guard recapEnabled else { return false }
        if !offlineMode.isOffline { return true }
        // Offline: nur wenn mindestens eine Recap-Playlist heruntergeladen ist.
        return !contentObserver.recapPlaylistIDs.isDisjoint(with: offlinePlaylistIDs)
    }

    private var visibleSmartMixes: [PersonalizationSmartMix] {
        PersonalizationSmartMix.allCases.filter(isSmartMixVisible)
    }

    private var orderedDiscoverySections: [PersonalizationDiscoverySection] {
        PersonalizationSettings.discoverySectionOrder(from: discoverySectionOrderRaw)
    }

    private var visibleDiscoverySections: [PersonalizationDiscoverySection] {
        orderedDiscoverySections.filter(isDiscoverySectionVisible)
    }

    @State private var mixLoading: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var randomRefreshing = false
    @State private var showInsights = false
    @State private var showRecap = false
    @State private var showRadioSheet = false
    @State private var deviceHasNetwork = true
    @State private var showConnectionRecoveryState = false
    @State private var isSwitchingServerURL = false
    @State private var serverURLSwitchGeneration = 0
    @State private var serverURLSwitchTask: Task<Void, Never>?
    @State private var locallyInitiatedURLSwitchSignature: String?
    @State private var discoverAirPlayRouteIsActive = false
    @State private var hasDownloads = DownloadUIStateHub.shared.hasDownloads
    @State private var offlinePlaylistIDs = DownloadStore.shared.offlinePlaylistIds

    private var activeServer: SubsonicServer? {
        serverStore.activeServer
    }

    private var activeServerURLSignature: String? {
        guard let activeServer else { return nil }
        return serverURLSignature(for: activeServer, slot: activeURLSlot(for: activeServer))
    }

    private var discoverTitle: String {
        let name = activeServer?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Shelv" : name
    }

    private var canSwitchServerURL: Bool {
        activeServer?.hasSecondaryURL == true
    }

    private var canSwitchMusicLibrary: Bool {
        musicLibraries.snapshot.showsSelector
    }

    private var showsServerMenu: Bool {
        canSwitchServerURL || canSwitchMusicLibrary
    }

    private var discoverContentIsEmpty: Bool {
        contentObserver.library.recentlyAdded.isEmpty
            && contentObserver.library.recentlyPlayed.isEmpty
            && contentObserver.library.frequentlyPlayed.isEmpty
            && contentObserver.library.randomAlbums.isEmpty
    }

    private var shouldShowDiscoverLoadingState: Bool {
        !offlineMode.isOffline
            && !showConnectionRecoveryState
            && (isSwitchingServerURL || (contentObserver.library.isLoadingDiscover && discoverContentIsEmpty))
    }

    private var shouldShowConnectionRecoveryState: Bool {
        !offlineMode.isOffline
            && discoverContentIsEmpty
            && showConnectionRecoveryState
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    discoverHeader

                    if offlineMode.isOffline {
                        if !hasDownloads {
                            offlineEmptyState
                        } else {
                            offlineMixState
                        }
                    } else if shouldShowDiscoverLoadingState {
                        discoverLoadingState
                    } else if shouldShowConnectionRecoveryState {
                        connectionRecoveryState
                    } else {
                        ForEach(Array(visibleDiscoverySections.enumerated()), id: \.element) { index, section in
                            discoveryAlbumSection(section, isFirstVisible: index == 0)
                        }

                        PlayerBottomSpacer()
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if recapButtonVisible {
                        Button {
                            showRecap = true
                        } label: {
                            Image(systemName: "calendar.badge.clock")
                        }
                    }
                    if showDiscoverInsights && !offlineMode.isOffline && deviceHasNetwork {
                        Button {
                            showInsights = true
                        } label: {
                            Image(systemName: "chart.bar.xaxis")
                        }
                    }
                    if showRadio && !offlineMode.isOffline && deviceHasNetwork {
                        Button {
                            showRadioSheet = true
                        } label: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                    }
                }
                if showDiscoverAirPlay {
                    ToolbarItem(placement: .topBarTrailing) {
                        discoverAirPlayButton
                    }
                }
            }
            .sheet(isPresented: $showInsights) {
                InsightsView()
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .sheet(isPresented: $showRecap) {
                RecapView()
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .sheet(isPresented: $showRadioSheet) {
                RadioStationsView()
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .refreshable {
                if await offlineMode.beginUserInitiatedServerRefresh() {
                    await updateDeviceNetworkState()
                    presentConnectionRecoveryState()
                    return
                }
                defer { offlineMode.finishUserInitiatedServerRefresh() }
                Task { await CloudKitSyncService.shared.syncNow() }
                await loadOnlineDiscoverContent(refreshRandom: true)
                await RadioStationStore.shared.refresh()
            }
            .task(id: contentObserver.library.reloadID) {
                await loadOnlineDiscoverContent()
            }
            .task {
                await updateDeviceNetworkState()
                updateDiscoverAirPlayRouteState()
            }
            .onAppear {
                contentObserver.setActive(isActive)
            }
            .onDisappear {
                contentObserver.setActive(false)
            }
            .onChange(of: isActive) { _, active in
                contentObserver.setActive(active)
            }
            .onReceive(NotificationCenter.default.publisher(for: .networkStatusChanged)) { _ in
                Task { await handleNetworkStatusChanged() }
            }
            .onReceive(DownloadUIStateHub.shared.hasDownloadsPublisher) { value in
                guard offlineMode.isOffline else { return }
                hasDownloads = value
            }
            .onReceive(downloadStore.$offlinePlaylistIds.removeDuplicates()) { playlistIDs in
                guard offlineMode.isOffline else { return }
                offlinePlaylistIDs = playlistIDs
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                updateDiscoverAirPlayRouteState()
            }
            .onChange(of: offlineMode.serverErrorBannerVisible) { _, visible in
                guard visible, discoverContentIsEmpty else { return }
                presentConnectionRecoveryState()
            }
            .onChange(of: offlineMode.isOffline) { _, isOffline in
                if isOffline {
                    hasDownloads = DownloadUIStateHub.shared.hasDownloads
                    offlinePlaylistIDs = downloadStore.offlinePlaylistIds
                    showRadioSheet = false
                    showConnectionRecoveryState = false
                } else {
                    Task { await loadOnlineDiscoverContent() }
                }
            }
            .onChange(of: activeServerURLSignature) { _, newSignature in
                guard let newSignature else { return }
                if locallyInitiatedURLSwitchSignature == newSignature {
                    locallyInitiatedURLSwitchSignature = nil
                    return
                }
                serverURLSwitchGeneration += 1
                let generation = serverURLSwitchGeneration
                serverURLSwitchTask?.cancel()
                serverURLSwitchTask = nil
                isSwitchingServerURL = true
                showConnectionRecoveryState = false
                offlineMode.clearServerError()
                libraryStore.resetDiscoverInMemory()
                RadioStationStore.shared.resetInMemory()
                Task { @MainActor in
                    defer {
                        if generation == serverURLSwitchGeneration {
                            isSwitchingServerURL = false
                        }
                    }
                    await loadOnlineDiscoverContent(ignoresVisibleServerError: true)
                    guard generation == serverURLSwitchGeneration else { return }
                    await RadioStationStore.shared.refresh()
                }
            }
            .alert(String(localized: "error"), isPresented: $showError, presenting: errorMessage) { _ in
                Button(String(localized: "ok"), role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
        }
    }

    private var discoverAirPlayButton: some View {
        ZStack {
            Button {} label: {
                discoverAirPlayIcon
            }
            .allowsHitTesting(false)

            AirPlayButton(tintColor: UIColor.clear, activeTintColor: UIColor.clear)
                .frame(width: 44, height: 44)
                .opacity(0.02)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AirPlay")
    }

    @ViewBuilder
    private var discoverAirPlayIcon: some View {
        if discoverAirPlayRouteIsActive {
            Image(systemName: "airplayaudio")
                .foregroundStyle(accentColor)
        } else {
            Image(systemName: "airplayaudio")
                .foregroundStyle(Color(UIColor.label))
        }
    }

    private func updateDiscoverAirPlayRouteState() {
        discoverAirPlayRouteIsActive = AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            switch output.portType {
            case .builtInReceiver, .builtInSpeaker:
                return false
            default:
                return true
            }
        }
    }

    @ViewBuilder
    private var discoverHeader: some View {
        Group {
            if showsServerMenu, let activeServer {
                Menu {
                    if canSwitchServerURL {
                        serverURLSlotMenuButton(slot: .primary, server: activeServer)
                        serverURLSlotMenuButton(slot: .secondary, server: activeServer)
                    }
                    if canSwitchServerURL && canSwitchMusicLibrary {
                        Divider()
                    }
                    if canSwitchMusicLibrary {
                        allMusicLibrariesMenuButton
                        Divider()
                        ForEach(musicLibraries.availableFolders) { folder in
                            musicLibraryMenuButton(folder)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(discoverTitle)
                            .font(.largeTitle.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Image(systemName: "chevron.down")
                            .font(.headline.weight(.semibold))
                            .padding(.top, 4)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(discoverTitle)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var allMusicLibrariesMenuButton: some View {
        let isSelected = musicLibraries.snapshot.selectsAllLibraries
        Button {
            musicLibraries.selectAll()
        } label: {
            HStack(spacing: 16) {
                Text(String(localized: "show_all_libraries"))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
        .disabled(isSelected)
    }

    @ViewBuilder
    private func musicLibraryMenuButton(_ folder: SubsonicMusicFolder) -> some View {
        let isSelected = musicLibraries.selectedFolderIDs == Set([folder.id])
        Button {
            musicLibraries.selectOnly(folderID: folder.id)
        } label: {
            HStack(spacing: 16) {
                Text(folder.name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
        .disabled(isSelected)
    }

    @ViewBuilder
    private func serverURLSlotMenuButton(slot: ServerURLSlot, server: SubsonicServer) -> some View {
        let isActive = activeURLSlot(for: server) == slot
        Button {
            guard !isActive else { return }
            startServerURLSlotSwitch(slot)
        } label: {
            Text(title(for: slot))
        }
            .foregroundStyle(isActive ? .secondary : .primary)
            .disabled(isActive)
    }

    private func activeURLSlot(for server: SubsonicServer) -> ServerURLSlot {
        server.isUsingSecondaryURL ? .secondary : .primary
    }

    private func serverURLSignature(for server: SubsonicServer, slot: ServerURLSlot) -> String {
        let baseURL = slot == .secondary && server.hasSecondaryURL
            ? (server.secondaryURL ?? server.baseURL)
            : server.baseURL
        return "\(server.id.uuidString)|\(slot.rawValue)|\(baseURL)"
    }

    private func title(for slot: ServerURLSlot) -> String {
        switch slot {
        case .primary:
            String(localized: "primary_url")
        case .secondary:
            String(localized: "secondary_url")
        }
    }

    @MainActor
    private func startServerURLSlotSwitch(_ slot: ServerURLSlot) {
        guard let server = activeServer else { return }
        guard activeURLSlot(for: server) != slot else { return }
        guard slot == .primary || server.hasSecondaryURL else { return }

        serverURLSwitchGeneration += 1
        let generation = serverURLSwitchGeneration
        let targetSignature = serverURLSignature(for: server, slot: slot)
        serverURLSwitchTask?.cancel()
        serverURLSwitchTask = Task { @MainActor in
            await switchServerURLSlot(
                slot,
                serverID: server.id,
                targetSignature: targetSignature,
                generation: generation
            )
        }
    }

    @MainActor
    private func switchServerURLSlot(
        _ slot: ServerURLSlot,
        serverID: UUID,
        targetSignature: String,
        generation: Int
    ) async {
        guard !Task.isCancelled else { return }
        isSwitchingServerURL = true
        showConnectionRecoveryState = false
        offlineMode.clearServerError()
        defer {
            if generation == serverURLSwitchGeneration {
                isSwitchingServerURL = false
                serverURLSwitchTask = nil
            }
        }

        locallyInitiatedURLSwitchSignature = targetSignature
        await serverStore.setURLSlot(for: serverID, slot: slot)

        libraryStore.resetDiscoverInMemory()

        if await offlineMode.beginUserInitiatedServerRefresh() {
            guard !Task.isCancelled, generation == serverURLSwitchGeneration else { return }
            await updateDeviceNetworkState()
            guard !Task.isCancelled, generation == serverURLSwitchGeneration else { return }
            presentConnectionRecoveryState()
            return
        }
        defer { offlineMode.finishUserInitiatedServerRefresh() }
        guard !Task.isCancelled, generation == serverURLSwitchGeneration else { return }

        await loadOnlineDiscoverContent(ignoresVisibleServerError: true)
        guard !Task.isCancelled, generation == serverURLSwitchGeneration else { return }
        await RadioStationStore.shared.refresh()
    }

    @MainActor
    private func loadOnlineDiscoverContent(
        refreshRandom: Bool = false,
        ignoresVisibleServerError: Bool = false
    ) async {
        let requestSignature = activeServerURLSignature
        showConnectionRecoveryState = false
        await updateDeviceNetworkState()
        guard !Task.isCancelled, requestSignature == activeServerURLSignature else { return }
        guard deviceHasNetwork else {
            let message = SubsonicAPIError.networkError(URLError(.notConnectedToInternet)).localizedDescription
            offlineMode.notifyServerErrorIfPresentationAllowed(message)
            presentConnectionRecoveryState()
            return
        }

        let didLoadDiscover: Bool
        if refreshRandom {
            didLoadDiscover = await libraryStore.loadDiscover()
            if didLoadDiscover {
                await libraryStore.refreshRandomAlbums()
            }
        } else {
            didLoadDiscover = await libraryStore.loadDiscover()
        }

        await updateDeviceNetworkState()
        guard !Task.isCancelled, requestSignature == activeServerURLSignature else { return }
        if discoverContentIsEmpty && (!deviceHasNetwork || (!ignoresVisibleServerError && offlineMode.serverErrorBannerVisible) || !didLoadDiscover) {
            presentConnectionRecoveryState()
        }
    }

    @MainActor
    private func updateDeviceNetworkState() async {
        await NetworkStatus.shared.waitUntilReady()
        deviceHasNetwork = NetworkStatus.shared.hasNetwork
    }

    @MainActor
    private func handleNetworkStatusChanged() async {
        let wasOffline = !deviceHasNetwork
        await updateDeviceNetworkState()
        if !deviceHasNetwork {
            presentConnectionRecoveryState()
        }
        guard wasOffline, deviceHasNetwork, !offlineMode.isOffline, discoverContentIsEmpty else { return }
        await loadOnlineDiscoverContent()
    }

    @MainActor
    private func presentConnectionRecoveryState() {
        guard discoverContentIsEmpty else { return }
        libraryStore.stopDiscoverLoadingForConnectionRecovery()
        showConnectionRecoveryState = true
    }

    @ViewBuilder
    private var offlineEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text(String(localized: "you_are_offline"))
                .font(.title3).bold()
            Text(String(localized: "downloads_are_still_available_tap_the_magnifying_g"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            Button {
                offlineMode.exitOfflineMode()
            } label: {
                Label(String(localized: "go_online"), systemImage: "wifi")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundStyle(accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private var discoverLoadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private var connectionRecoveryState: some View {
        VStack(spacing: 0) {
            Button {
                offlineMode.enterOfflineMode()
            } label: {
                Label(String(localized: "go_offline"), systemImage: "wifi.slash")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundStyle(accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private var offlineMixState: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                mixButton(
                    title: String(localized: "play_all_downloads"),
                    icon: "play.fill",
                    key: "offline_play"
                ) { loadOfflineMix(type: "offline_play") }

                mixButton(
                    title: String(localized: "shuffle_all_downloads"),
                    icon: "shuffle",
                    key: "offline_shuffle"
                ) { loadOfflineMix(type: "offline_shuffle") }

                mixButton(
                    title: String(localized: "mix_latest_downloads"),
                    icon: "clock.fill",
                    key: "offline_newest"
                ) { loadOfflineMix(type: "offline_newest") }
            }
            .padding(.horizontal)

            HStack {
                Spacer()
                Button {
                    offlineMode.exitOfflineMode()
                } label: {
                    Label(String(localized: "go_online"), systemImage: "wifi")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(accentColor.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var randomAlbumSection: some View {
        albumSection(title: String(localized: "random_albums"), albums: contentObserver.library.randomAlbums) {
            Button {
                randomRefreshing = true
                Task {
                    await libraryStore.refreshRandomAlbums()
                    randomRefreshing = false
                }
            } label: {
                Image(systemName: "shuffle")
                    .font(.body)
                    .foregroundStyle(accentColor)
                    .rotationEffect(.degrees(randomRefreshing ? 360 : 0))
                    .animation(
                        randomRefreshing ? .linear(duration: 0.5).repeatForever(autoreverses: false) : .default,
                        value: randomRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(randomRefreshing)
        }
    }

    private func isSmartMixVisible(_ mix: PersonalizationSmartMix) -> Bool {
        switch mix {
        case .newest: return showSmartMixNewest
        case .frequent: return showSmartMixFrequent
        case .recent: return showSmartMixRecent
        case .random: return showSmartMixRandom
        }
    }

    private func isDiscoverySectionVisible(_ section: PersonalizationDiscoverySection) -> Bool {
        switch section {
        case .smartMixes:
            #if DEBUG
            if SubsonicAPIService.shared.isDemoActive {
                return !visibleSmartMixes.isEmpty
            }
            #endif
            return !visibleSmartMixes.isEmpty && !discoverContentIsEmpty
        case .recentlyAdded:
            return !contentObserver.library.recentlyAdded.isEmpty
        case .recentlyPlayed:
            return !contentObserver.library.recentlyPlayed.isEmpty
        case .frequentlyPlayed:
            return !contentObserver.library.frequentlyPlayed.isEmpty
        case .randomAlbums:
            return !contentObserver.library.randomAlbums.isEmpty
        }
    }

    @ViewBuilder
    private func smartMixButton(for mix: PersonalizationSmartMix) -> some View {
        mixButton(
            title: NSLocalizedString(mix.titleKey, comment: ""),
            icon: mix.systemImage,
            key: mix.playbackKey
        ) {
            await loadMix(type: mix.playbackKey)
        }
    }

    @ViewBuilder
    private func discoveryAlbumSection(_ section: PersonalizationDiscoverySection, isFirstVisible: Bool) -> some View {
        switch section {
        case .smartMixes:
            VStack(alignment: .leading, spacing: 10) {
                if !isFirstVisible {
                    Text(String(localized: "smart_mixes"))
                        .font(.title3).bold()
                        .padding(.horizontal)
                }
                VStack(spacing: 12) {
                    ForEach(visibleSmartMixes) { mix in
                        smartMixButton(for: mix)
                    }
                }
                .padding(.horizontal)
            }
        case .recentlyAdded:
            albumSection(
                title: String(localized: "recently_added"),
                albums: contentObserver.library.recentlyAdded
            )
        case .recentlyPlayed:
            albumSection(
                title: String(localized: "recently_played"),
                albums: contentObserver.library.recentlyPlayed
            )
        case .frequentlyPlayed:
            albumSection(
                title: String(localized: "frequently_played"),
                albums: contentObserver.library.frequentlyPlayed
            )
        case .randomAlbums:
            randomAlbumSection
        }
    }

    @ViewBuilder
    private func albumSection<T: View>(title: String, albums: [Album], @ViewBuilder trailingButton: () -> T = { EmptyView() }) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(.title3).bold()
                    Spacer()
                    trailingButton()
                }
                .padding(.horizontal)

                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCardView(
                                    album: album,
                                    personalization: personalization,
                                    fixedSize: 140,
                                    showArtist: true
                                )
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    private func mixButton(
        title: String,
        icon: String,
        key: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task {
                mixLoading = key
                await action()
                mixLoading = nil
            }
        } label: {
            HStack {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 28)
                Text(title)
                    .font(.body).bold()
                Spacer()
                if mixLoading == key {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(accentColor)
            .clipShape(Capsule())
        }
        .disabled(mixLoading != nil)
    }

    private func loadOfflineMix(type: String) {
        guard !downloadStore.songs.isEmpty else { return }
        let mode: ShortcutDownloadsMode
        switch type {
        case "offline_play": mode = .all
        case "offline_shuffle": mode = .shuffled
        case "offline_newest": mode = .newest
        default: return
        }
        let selection = DownloadedPlaybackQueueBuilder.selection(
            from: downloadStore.songs,
            mode: mode
        )
        switch selection.order {
        case .inOrder: player.play(songs: selection.songs)
        case .shuffled: player.playShuffled(songs: selection.songs)
        }
    }

    private func loadMix(type: String) async {
        do {
            let mix: ShortcutSmartMix
            switch type {
            case "newest": mix = .newest
            case "frequent": mix = .frequent
            case "random": mix = .shuffleAll
            default: mix = .recent
            }
            let songs = try await SmartMixPlaybackService.songs(for: mix)
            player.playShuffled(songs: songs)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
