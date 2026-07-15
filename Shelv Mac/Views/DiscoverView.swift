import SwiftUI
import OSLog

private let discoverViewLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ch.vkugler.Shelv",
    category: "DiscoverStartup"
)

struct DiscoverView: View {
    private enum LoadTrigger: String {
        case initialTask
        case offlineExit
        case serverChange
        case serverURLChange
        case serverURLSwitch
        case manualRefresh
        case networkRecovered
    }

    @ObservedObject private var vm = DiscoverViewModel.shared
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @AppStorage("themeColor") private var themeColorName: String = "violet"
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage(PersonalizationPreferenceKey.showDiscoverInsights) private var showDiscoverInsights = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixNewest) private var showSmartMixNewest = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixFrequent) private var showSmartMixFrequent = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixRecent) private var showSmartMixRecent = true
    @AppStorage(PersonalizationPreferenceKey.showSmartMixRandom) private var showSmartMixRandom = true
    @AppStorage(PersonalizationPreferenceKey.discoverySectionOrder) private var discoverySectionOrderRaw = PersonalizationSettings.defaultDiscoverySectionOrderRaw
    @State private var mixLoading: String?
    @State private var deviceHasNetwork = true
    @State private var showConnectionRecoveryState = false
    @State private var showDiscoverLoadFailureState = false
    @State private var isCheckingConnection = false
    @State private var isRefreshingDiscover = false
    @State private var isSwitchingServerURL = false
    @State private var serverURLSwitchGeneration = 0
    @State private var serverURLSwitchTask: Task<Void, Never>?
    @State private var locallyInitiatedURLSwitchSignature: String?
    private let player = AudioPlayerService.shared

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

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

    private var visibleSmartMixes: [PersonalizationSmartMix] {
        PersonalizationSmartMix.allCases.filter(isSmartMixVisible)
    }

    private var orderedDiscoverySections: [PersonalizationDiscoverySection] {
        PersonalizationSettings.discoverySectionOrder(from: discoverySectionOrderRaw)
    }

    private var visibleDiscoverySections: [PersonalizationDiscoverySection] {
        orderedDiscoverySections.filter(isDiscoverySectionVisible)
    }

    private var discoverContentIsEmpty: Bool {
        vm.recentlyAdded.isEmpty
            && vm.recentlyPlayed.isEmpty
            && vm.frequentlyPlayed.isEmpty
            && vm.randomAlbums.isEmpty
    }

    private var shouldShowDiscoverLoadingState: Bool {
        !offlineMode.isOffline
            && !shouldShowConnectionRecoveryState
            && (isSwitchingServerURL || (discoverContentIsEmpty && (vm.isLoading || isCheckingConnection)))
    }

    private var shouldShowConnectionRecoveryState: Bool {
        !offlineMode.isOffline
            && !isCheckingConnection
            && discoverContentIsEmpty
            && (showConnectionRecoveryState || offlineMode.serverErrorBannerVisible)
    }

    private var hasLeadingToolbarActions: Bool {
        recapEnabled || showDiscoverInsights
    }

    @ViewBuilder
    var body: some View {
        if offlineMode.isOffline {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    discoverHeader

                    Group {
                        if downloadStore.songs.isEmpty {
                            offlineEmptyState
                        } else {
                            offlineMixState
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle(String(localized: "discover"))
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    OfflineRecapToolbarItem()
                }
                ToolbarItem(placement: .primaryAction) {
                    ThemePickerButton()
                }
            }
            .onChange(of: offlineMode.isOffline) { _, isOffline in
                if !isOffline {
                    Task {
                        await loadOnlineDiscoverContent(
                            trigger: .offlineExit,
                            verifyReachabilityFirst: discoverContentIsEmpty
                        )
                    }
                }
            }
        } else {
            onlineBody
        }
    }

    private var offlineMixState: some View {
        VStack(spacing: 20) {
            Text(String(localized: "offline_mixes"))
                .font(.title2).bold()
            VStack(spacing: 10) {
                MixButton(
                    title: String(localized: "play_all_downloads"),
                    icon: "play.fill",
                    isLoading: mixLoading == "offline_play"
                ) {
                    mixLoading = "offline_play"
                    loadOfflineMix(type: "offline_play")
                    mixLoading = nil
                }
                MixButton(
                    title: String(localized: "shuffle_all_downloads"),
                    icon: "shuffle",
                    isLoading: mixLoading == "offline_shuffle"
                ) {
                    mixLoading = "offline_shuffle"
                    loadOfflineMix(type: "offline_shuffle")
                    mixLoading = nil
                }
                MixButton(
                    title: String(localized: "mix_latest_downloads"),
                    icon: "arrow.down.circle.fill",
                    isLoading: mixLoading == "offline_newest"
                ) {
                    mixLoading = "offline_newest"
                    loadOfflineMix(type: "offline_newest")
                    mixLoading = nil
                }
            }
            .frame(maxWidth: 480)
            Button {
                offlineMode.exitOfflineMode()
            } label: {
                Label(String(localized: "go_online"), systemImage: "wifi")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var offlineEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text(String(localized: "you_are_offline"))
                .font(.title2.bold())
            Text(String(localized: "switch_to_your_downloads_in_the_sidebar_or_use_sea"))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            Button {
                offlineMode.exitOfflineMode()
            } label: {
                Label(String(localized: "go_online"), systemImage: "wifi")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var onlineBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                discoverHeader

                if shouldShowDiscoverLoadingState {
                    discoverLoadingState
                } else if shouldShowConnectionRecoveryState {
                    connectionRecoveryState
                } else if showDiscoverLoadFailureState && discoverContentIsEmpty {
                    discoverLoadFailureState
                } else {
                    ForEach(Array(visibleDiscoverySections.enumerated()), id: \.element) { index, section in
                        discoveryAlbumSection(section, isFirstVisible: index == 0)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(String(localized: "discover"))
        .toolbar {
            if recapEnabled {
                ToolbarItem(placement: .automatic) {
                    RecapToolbarButton()
                }
            }
            if showDiscoverInsights {
                ToolbarItem(placement: .automatic) {
                    InsightsToolbarButton()
                }
            }
            if hasLeadingToolbarActions {
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .automatic)
                } else {
                    ToolbarItem(placement: .automatic) {
                        Divider()
                            .frame(height: 22)
                            .padding(.horizontal, 8)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refreshOnlineDiscoverContent() }
                } label: {
                    RefreshToolbarIcon(isRefreshing: isRefreshingDiscover)
                }
                .disabled(isCheckingConnection || isSwitchingServerURL || (vm.isLoading && !shouldShowConnectionRecoveryState))
                .help(String(localized: "reload"))
            }
            ToolbarItem(placement: .primaryAction) {
                ThemePickerButton()
            }
        }
        .task {
            await loadOnlineDiscoverContent(
                trigger: .initialTask,
                verifyReachabilityFirst: discoverContentIsEmpty
            )
        }
        .task {
            await updateDeviceNetworkState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .networkStatusChanged)) { _ in
            Task { await handleNetworkStatusChanged() }
        }
        .onChange(of: serverStore.activeServerID) { _, _ in
            serverURLSwitchGeneration += 1
            serverURLSwitchTask?.cancel()
            serverURLSwitchTask = nil
            locallyInitiatedURLSwitchSignature = activeServerURLSignature
            isSwitchingServerURL = false
            isCheckingConnection = false
            showDiscoverLoadFailureState = false
            offlineMode.clearServerError()
            vm.reset()
            Task {
                await loadOnlineDiscoverContent(
                    trigger: .serverChange,
                    verifyReachabilityFirst: true
                )
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
            isCheckingConnection = true
            showConnectionRecoveryState = false
            showDiscoverLoadFailureState = false
            offlineMode.clearServerError()
            vm.reset()
            RadioStationStore.shared.resetInMemory()
            Task { @MainActor in
                defer {
                    if generation == serverURLSwitchGeneration {
                        isSwitchingServerURL = false
                        isCheckingConnection = false
                    }
                }
                await loadOnlineDiscoverContent(
                    trigger: .serverURLChange,
                    verifyReachabilityFirst: true
                )
                guard generation == serverURLSwitchGeneration else { return }
                await RadioStationStore.shared.refresh()
            }
        }
    }

    @ViewBuilder
    private var discoverHeader: some View {
        Group {
            if canSwitchServerURL, let activeServer {
                Menu {
                    serverURLSlotMenuButton(slot: .primary, server: activeServer)
                    serverURLSlotMenuButton(slot: .secondary, server: activeServer)
                } label: {
                    HStack(spacing: 6) {
                        Text(discoverTitle)
                            .font(.title2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .padding(.top, 2)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(discoverTitle)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder
    private func serverURLSlotMenuButton(slot: ServerURLSlot, server: SubsonicServer) -> some View {
        let isActive = activeURLSlot(for: server) == slot
        Button {
            guard !isActive else { return }
            startServerURLSlotSwitch(slot)
        } label: {
            HStack(spacing: 16) {
                Text(title(for: slot))
                Spacer()
                Image(systemName: "checkmark")
                    .opacity(isActive ? 1 : 0)
            }
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
        isCheckingConnection = true
        showConnectionRecoveryState = false
        showDiscoverLoadFailureState = false
        offlineMode.clearServerError()
        defer {
            if generation == serverURLSwitchGeneration {
                isSwitchingServerURL = false
                isCheckingConnection = false
                serverURLSwitchTask = nil
            }
        }

        locallyInitiatedURLSwitchSignature = targetSignature
        await serverStore.setURLSlot(for: serverID, slot: slot)
        vm.reset()
        RadioStationStore.shared.resetInMemory()

        if await offlineMode.beginUserInitiatedServerRefresh() {
            guard !Task.isCancelled, generation == serverURLSwitchGeneration else { return }
            await updateDeviceNetworkState()
            guard !Task.isCancelled, generation == serverURLSwitchGeneration else { return }
            presentConnectionRecoveryState()
            return
        }
        defer { offlineMode.finishUserInitiatedServerRefresh() }
        guard !Task.isCancelled, generation == serverURLSwitchGeneration else { return }

        await loadOnlineDiscoverContent(
            trigger: .serverURLSwitch,
            verifyReachabilityFirst: false
        )
        guard !Task.isCancelled, generation == serverURLSwitchGeneration else { return }
        await RadioStationStore.shared.refresh()
    }

    @MainActor
    private func refreshOnlineDiscoverContent() async {
        guard !isRefreshingDiscover, !isCheckingConnection, !isSwitchingServerURL else { return }
        guard !vm.isLoading || shouldShowConnectionRecoveryState else { return }

        isRefreshingDiscover = true
        defer { isRefreshingDiscover = false }
        showConnectionRecoveryState = false
        showDiscoverLoadFailureState = false
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        if await offlineMode.beginUserInitiatedServerRefresh() {
            await updateDeviceNetworkState()
            presentConnectionRecoveryState()
            return
        }
        defer { offlineMode.finishUserInitiatedServerRefresh() }

        Task { await CloudKitSyncService.shared.syncNow() }
        async let discover: Void = loadOnlineDiscoverContent(
            trigger: .manualRefresh,
            verifyReachabilityFirst: false,
            force: true
        )
        async let playlists: Void = libraryStore.loadPlaylists(force: true)
        async let radio:     Void = RadioStationStore.shared.refresh()
        _ = await (discover, playlists, radio)
    }

    @MainActor
    private func loadOnlineDiscoverContent(
        trigger: LoadTrigger,
        verifyReachabilityFirst: Bool = false,
        force: Bool = false
    ) async {
        let requestSignature = activeServerURLSignature
        discoverViewLogger.info(
            "View load started trigger=\(trigger.rawValue, privacy: .public) verify=\(verifyReachabilityFirst) force=\(force) empty=\(discoverContentIsEmpty) banner=\(offlineMode.serverErrorBannerVisible)"
        )
        showConnectionRecoveryState = false
        showDiscoverLoadFailureState = false
        await updateDeviceNetworkState()
        guard !Task.isCancelled, requestSignature == activeServerURLSignature else {
            discoverViewLogger.info("View load superseded before reachability")
            return
        }
        guard deviceHasNetwork else {
            discoverViewLogger.error("Recovery selected: device network unavailable")
            let message = SubsonicAPIError.networkError(URLError(.notConnectedToInternet)).localizedDescription
            offlineMode.notifyServerErrorIfPresentationAllowed(message)
            presentConnectionRecoveryState()
            return
        }

        var shouldFinishReachabilityCheck = false
        defer {
            if shouldFinishReachabilityCheck {
                offlineMode.finishUserInitiatedServerRefresh()
            }
        }

        if verifyReachabilityFirst && discoverContentIsEmpty {
            isCheckingConnection = true
            let reachability = await offlineMode.beginVisibleServerReachabilityCheck()
            if reachability == .cancelled {
                discoverViewLogger.info("Reachability cancelled")
                isCheckingConnection = false
                return
            }
            if reachability == .unreachable {
                discoverViewLogger.error("Recovery selected: server ping failed")
                isCheckingConnection = false
                await updateDeviceNetworkState()
                guard !Task.isCancelled, requestSignature == activeServerURLSignature else { return }
                presentConnectionRecoveryState()
                return
            }
            discoverViewLogger.info("Reachability succeeded")
            isCheckingConnection = false
            shouldFinishReachabilityCheck = true
        }

        let didLoadDiscover = await vm.load(force: force)

        await updateDeviceNetworkState()
        guard !Task.isCancelled, requestSignature == activeServerURLSignature else {
            discoverViewLogger.info("View load superseded after content request")
            return
        }
        showConnectionRecoveryState = discoverContentIsEmpty && !deviceHasNetwork
        showDiscoverLoadFailureState = discoverContentIsEmpty && deviceHasNetwork && !didLoadDiscover
        discoverViewLogger.info(
            "View load resolved success=\(didLoadDiscover) empty=\(discoverContentIsEmpty) recovery=\(showConnectionRecoveryState) contentFailure=\(showDiscoverLoadFailureState)"
        )
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
        await loadOnlineDiscoverContent(
            trigger: .networkRecovered,
            verifyReachabilityFirst: true
        )
    }

    @MainActor
    private func presentConnectionRecoveryState() {
        guard discoverContentIsEmpty else { return }
        discoverViewLogger.error(
            "Recovery presented network=\(deviceHasNetwork) checking=\(isCheckingConnection) banner=\(offlineMode.serverErrorBannerVisible)"
        )
        isCheckingConnection = false
        vm.stopLoadingForConnectionRecovery()
        showConnectionRecoveryState = true
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
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private var discoverLoadFailureState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(String(localized: "error"))
                .font(.headline)
            Button(String(localized: "reload")) {
                Task { await refreshOnlineDiscoverContent() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
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
            return !vm.recentlyAdded.isEmpty
        case .recentlyPlayed:
            return !vm.recentlyPlayed.isEmpty
        case .frequentlyPlayed:
            return !vm.frequentlyPlayed.isEmpty
        case .randomAlbums:
            return !vm.randomAlbums.isEmpty
        }
    }

    @ViewBuilder
    private func smartMixButton(for mix: PersonalizationSmartMix) -> some View {
        MixButton(
            title: NSLocalizedString(mix.titleKey, comment: ""),
            icon: mix.systemImage,
            isLoading: mixLoading == mix.playbackKey
        ) {
            mixLoading = mix.playbackKey
            await playSmartMix(mix)
            mixLoading = nil
        }
    }

    private func playSmartMix(_ mix: PersonalizationSmartMix) async {
        switch mix {
        case .newest:
            await vm.playMixNewest()
        case .frequent:
            await vm.playMixFrequent()
        case .recent:
            await vm.playMixRecent()
        case .random:
            await vm.playMixRandom()
        }
    }

    @ViewBuilder
    private func discoveryAlbumSection(_ section: PersonalizationDiscoverySection, isFirstVisible: Bool) -> some View {
        switch section {
        case .smartMixes:
            VStack(alignment: .leading, spacing: 12) {
                if !isFirstVisible {
                    Text(String(localized: "smart_mixes"))
                        .font(.title2).bold()
                }
                VStack(spacing: 10) {
                    ForEach(visibleSmartMixes) { mix in
                        smartMixButton(for: mix)
                    }
                }
            }
        case .recentlyAdded:
            if !vm.recentlyAdded.isEmpty {
                AlbumShelfSection(title: String(localized: "recently_added"), albums: vm.recentlyAdded)
            }
        case .recentlyPlayed:
            if !vm.recentlyPlayed.isEmpty {
                AlbumShelfSection(title: String(localized: "recently_played"), albums: vm.recentlyPlayed)
            }
        case .frequentlyPlayed:
            if !vm.frequentlyPlayed.isEmpty {
                AlbumShelfSection(title: String(localized: "frequently_played"), albums: vm.frequentlyPlayed)
            }
        case .randomAlbums:
            if !vm.randomAlbums.isEmpty {
                AlbumShelfSection(
                    title: String(localized: "random_albums"),
                    albums: vm.randomAlbums,
                    refreshAction: { await vm.refreshRandom() }
                )
            }
        }
    }
}

private struct RefreshToolbarIcon: View {
    let isRefreshing: Bool
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Image(systemName: "arrow.clockwise")
                .opacity(isRefreshing ? 0 : 1)

            Circle()
                .trim(from: 0.18, to: 0.82)
                .stroke(
                    Color.primary,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(rotation))
                .opacity(isRefreshing ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            updateRotation()
        }
        .onChange(of: isRefreshing) { _, _ in
            updateRotation()
        }
    }

    private func updateRotation() {
        if isRefreshing {
            rotation = 0
            withAnimation(.linear(duration: 0.75).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                rotation = 0
            }
        }
    }
}

struct MixButton: View {
    let title: String
    let icon: String
    let isLoading: Bool
    let action: () async -> Void

    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Button {
            guard !isLoading else { return }
            Task { await action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 28)
                Text(title)
                    .font(.body.bold())
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                Capsule(style: .continuous)
                    .fill(themeColor)
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(MixButtonPressStyle())
        .allowsHitTesting(!isLoading)
    }
}

private struct MixButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.035 : 0)
            .overlay {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.10 : 0))
            }
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct AlbumShelfSection: View {
    let title: String
    let albums: [Album]
    var refreshAction: (() async -> Void)? = nil

    private let cardWidth: CGFloat   = 150
    private let cardSpacing: CGFloat  = 16
    private let shelfHeight: CGFloat  = 196
    private let cardsPerStep: Int     = 3

    @State private var firstVisible: Int = 0
    @State private var isRefreshing = false

    private var atStart: Bool { firstVisible == 0 }
    private var atEnd: Bool   { firstVisible + cardsPerStep >= albums.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.title2).bold()
                Spacer()
                HStack(spacing: 6) {
                    if let refreshAction {
                        ShelfNavButton(icon: isRefreshing ? "arrow.clockwise" : "dice", disabled: isRefreshing) {
                            isRefreshing = true
                            firstVisible = 0
                            await refreshAction()
                            isRefreshing = false
                        }
                    }
                    ShelfNavButton(icon: "chevron.left", disabled: atStart) {
                        firstVisible = max(0, firstVisible - cardsPerStep)
                    }
                    ShelfNavButton(icon: "chevron.right", disabled: atEnd) {
                        firstVisible = min(albums.count - cardsPerStep, firstVisible + cardsPerStep)
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: cardSpacing) {
                        ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album)
                            .id(index)
                        }
                    }
                    .padding(.leading, 2)
                    .padding(.top, 8)
                }
                .frame(height: shelfHeight + 8)
                .clipped()
                .onChange(of: firstVisible) { _, newValue in
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(newValue, anchor: .leading)
                    }
                }
            }
        }
    }
}

struct ShelfNavButton: View {
    let icon: String
    let disabled: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.callout.bold())
                .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 28)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct AlbumCard: View {
    let album: Album
    @State private var isHovered = false

    private var coverURL: URL? {
        guard let id = album.coverArt else { return nil }
        return SubsonicAPIService.shared.coverArtURL(id: id, size: 200)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverArtView(url: coverURL, size: 150, cornerRadius: 8)
                .overlay(alignment: .bottomTrailing) {
                    AlbumDownloadBadge(albumId: album.id)
                        .padding(4)
                }
                .shadow(color: .black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 8 : 4)
            Text(album.name)
                .font(.caption.bold())
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            if let artist = album.artist {
                Text(artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
            }
        }
        .scaleEffect(isHovered ? 1.03 : 1.0, anchor: .bottom)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct InsightsToolbarButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Button {
            openWindow(id: "insights")
        } label: {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(themeColor)
        }
        .help(String(localized: "insights"))
    }
}

struct RecapToolbarButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Button {
            openWindow(id: "recap")
        } label: {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(themeColor)
        }
        .help(String(localized: "recap"))
    }
}

struct ThemePickerButton: View {
    @AppStorage("themeColor") private var themeColorName: String = "violet"
    @State private var showPicker = false

    var body: some View {
        Button { showPicker.toggle() } label: {
            Image(systemName: "paintpalette.fill")
                .foregroundStyle(AppTheme.color(for: themeColorName))
        }
        .help(String(localized: "choose_color"))
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            ThemePickerPopover(themeColorName: $themeColorName)
        }
    }
}

struct ThemePickerPopover: View {
    @Binding var themeColorName: String

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 10), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "color"))
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AppTheme.options, id: \.name) { option in
                    Button {
                        themeColorName = option.name
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 34, height: 34)
                            .overlay {
                                if themeColorName == option.name {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(
                                            option.useDarkCheckmark ? Color.black : Color.white
                                        )
                                }
                            }
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help(appLang == "de" ? option.nameDE : option.nameEN)
                }
            }
        }
        .padding(16)
        .frame(width: 240)
    }
}

private struct OfflineRecapToolbarItem: View {
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var recapStore = RecapStore.shared
    @AppStorage("recapEnabled") private var recapEnabled = false

    var body: some View {
        if recapEnabled && !downloadStore.downloadedPlaylistIds.isDisjoint(with: recapStore.recapPlaylistIds) {
            RecapToolbarButton()
        }
    }
}

private func desktopStripArticle(_ title: String) -> String {
    LibrarySortKey.removingLeadingArticle(from: title)
}

#Preview {
    DiscoverView()
        .frame(width: 900, height: 700)
        .environmentObject(AppState.shared)
        .environmentObject(AppState.shared.serverStore)
}
