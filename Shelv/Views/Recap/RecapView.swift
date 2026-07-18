import Combine
import SwiftUI

struct RecapView: View {
    @EnvironmentObject var recapStore: RecapStore
    @EnvironmentObject var serverStore: ServerStore
    @ObservedObject var libraryStore = LibraryStore.shared
    private let downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("recapWeeklyEnabled") private var weeklyEnabled = true
    @AppStorage("recapMonthlyEnabled") private var monthlyEnabled = true
    @AppStorage("recapYearlyEnabled") private var yearlyEnabled = true
    @AppStorage("enableDownloads") private var enableDownloads = true

    @State private var segment: RecapPeriod.PeriodType = .week
    @State private var selectedEntry: RecapRegistryRecord?
    @State private var entryToDelete: RecapRegistryRecord?
    @State private var showDeleteConfirm = false
    @State private var currentToast: ShelveToast?
    @State private var entryToDeleteDownloads: RecapRegistryRecord?
    @State private var offlinePlaylistIDs = DownloadStore.shared.offlinePlaylistIds

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var enabledTypes: [RecapPeriod.PeriodType] {
        var types: [RecapPeriod.PeriodType] = []
        if weeklyEnabled  { types.append(.week) }
        if monthlyEnabled { types.append(.month) }
        if yearlyEnabled  { types.append(.year) }
        return types
    }

    private var filteredEntries: [RecapRegistryRecord] {
        let typed = recapStore.entries.filter { $0.periodType == segment.rawValue }
        // Im Offline-Modus nur Recap-Playlists anzeigen, die heruntergeladen sind —
        // ungeladene Recaps sind ohne Server unspielbar.
        return offlineMode.isOffline
            ? typed.filter { offlinePlaylistIDs.contains($0.playlistId) }
            : typed
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !recapEnabled {
                    disabledStateView
                } else if enabledTypes.isEmpty {
                    emptyStateView(
                        icon: "chart.bar.xaxis",
                        message: String(localized: "enable_at_least_one_period_in_settings")
                    )
                } else {
                    if enabledTypes.count > 1 {
                        Picker("", selection: $segment) {
                            ForEach(enabledTypes, id: \.self) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                    }

                    if filteredEntries.isEmpty {
                        emptyStateView(
                            icon: "clock",
                            message: String(localized: "no_recap_generated_yet_for_this_period")
                        )
                    } else {
                        List {
                            ForEach(filteredEntries, id: \.playlistId) { entry in
                                OfflinePlaylistAvailabilityReader(playlistID: entry.playlistId) { isMarkedForOffline in
                                    Button { selectedEntry = entry } label: {
                                        recapRow(entry)
                                    }
                                    .buttonStyle(.plain)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .listRowBackground(Color.clear)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            haptic(); Task { await addRecapToQueue(entry) }
                                        } label: { Image(systemName: "text.badge.plus") }
                                        .tint(accentColor)
                                        Button {
                                            haptic(); Task { await playRecapNext(entry) }
                                        } label: { Image(systemName: "text.insert") }
                                        .tint(.orange)
                                        if enableDownloads {
                                            recapDownloadSwipe(
                                                entry,
                                                isMarkedForOffline: isMarkedForOffline
                                            )
                                        }
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            entryToDelete = entry
                                            showDeleteConfirm = true
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .tint(.red)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .refreshable {
                            if await OfflineModeService.shared.beginUserInitiatedServerRefresh() { return }
                            defer { OfflineModeService.shared.finishUserInitiatedServerRefresh() }
                            guard let sid = serverStore.activeServer?.stableId else { return }
                            Task { await CloudKitSyncService.shared.syncNow() }
                            async let cleanup:  Void = recapStore.refreshWithCleanup(serverId: sid)
                            async let playlists: Void = libraryStore.loadPlaylists()
                            _ = await (cleanup, playlists)
                        }
                        .navigationDestination(item: $selectedEntry) { entry in
                            recapDetail(entry)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "recap"))
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .tint(accentColor)
        .shelveToast($currentToast)
        .alert(
            String(localized: "delete_recap_2"),
            isPresented: $showDeleteConfirm,
            presenting: entryToDelete
        ) { entry in
            Button(String(localized: "delete"), role: .destructive) {
                guard let sid = serverStore.activeServer?.stableId else { return }
                Task {
                    do {
                        try await recapStore.deleteEntry(playlistId: entry.playlistId, serverId: sid)
                    } catch {
                        if !(error is CancellationError) {
                            currentToast = ShelveToast(message: String(localized: "could_not_delete_playlist"), isError: true)
                        }
                    }
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: { entry in
            let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
            let period = RecapPeriod(
                type: type,
                start: Date(timeIntervalSince1970: entry.periodStart),
                end: Date(timeIntervalSince1970: entry.periodEnd)
            )
            Text(period.playlistName)
        }
        .alert(
            String(localized: "delete_downloads"),
            isPresented: Binding(get: { entryToDeleteDownloads != nil }, set: { if !$0 { entryToDeleteDownloads = nil } }),
            presenting: entryToDeleteDownloads
        ) { entry in
            Button(String(localized: "delete"), role: .destructive) {
                deleteRecapDownloads(entry)
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
        .onAppear {
            if let first = enabledTypes.first, !enabledTypes.contains(segment) {
                segment = first
            }
        }
        .onReceive(downloadStore.$offlinePlaylistIds.removeDuplicates()) { playlistIDs in
            guard offlineMode.isOffline else { return }
            offlinePlaylistIDs = playlistIDs
        }
        .onChange(of: offlineMode.isOffline) { _, isOffline in
            guard isOffline else { return }
            offlinePlaylistIDs = downloadStore.offlinePlaylistIds
        }
        .task(id: serverStore.activeServerID) {
            guard let sid = serverStore.activeServer?.stableId else { return }
            async let cleanup:   Void = recapStore.refreshWithCleanup(serverId: sid)
            async let playlists: Void = libraryStore.loadPlaylists()
            _ = await (cleanup, playlists)
        }
    }

    // MARK: - Row

    private func recapRow(_ entry: RecapRegistryRecord) -> some View {
        let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
        let period = RecapPeriod(
            type: type,
            start: Date(timeIntervalSince1970: entry.periodStart),
            end: Date(timeIntervalSince1970: entry.periodEnd)
        )
        let isMissing = !libraryStore.playlists.isEmpty
            && !libraryStore.playlists.contains { $0.id == entry.playlistId }
        let iconColor: Color = isMissing ? .orange : accentColor
        let iconName = isMissing ? "exclamationmark.triangle.fill" : type.icon
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.1))
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(period.playlistName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.isTest {
                        Text("TEST")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.orange, lineWidth: 1)
                            )
                    }
                }
                Text("Top \(type.songLimit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            PlaylistDownloadBadge(playlistId: entry.playlistId)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Detail Navigation

    @ViewBuilder
    private func recapDetail(_ entry: RecapRegistryRecord) -> some View {
        if let sid = serverStore.activeServer?.stableId {
            RecapDetailView(entry: entry, serverId: sid)
        }
    }

    // MARK: - State Views

    private var disabledStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text(String(localized: "recap_is_disabled"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(String(localized: "enable_recap_in_settings_to_start_tracking_your_listening_history"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStateView(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Swipe-Actions

    @ViewBuilder
    private func recapDownloadSwipe(
        _ entry: RecapRegistryRecord,
        isMarkedForOffline: Bool
    ) -> some View {
        if isMarkedForOffline {
            Button {
                haptic(); entryToDeleteDownloads = entry
            } label: { Image(systemName: DownloadActionSymbols.delete) }
            .tint(.red)
        } else if !offlineMode.isOffline {
            Button {
                haptic(); Task { await downloadRecap(entry) }
            } label: { Image(systemName: "arrow.down.circle") }
            .tint(accentColor)
        }
    }

    private func addRecapToQueue(_ entry: RecapRegistryRecord) async {
        guard let loaded = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
              let songs = loaded.songs, !songs.isEmpty else { return }
        await MainActor.run {
            AudioPlayerService.shared.addToQueue(songs)
            currentToast = ShelveToast(message: String(localized: "added_to_queue"))
        }
    }

    private func playRecapNext(_ entry: RecapRegistryRecord) async {
        guard let loaded = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
              let songs = loaded.songs, !songs.isEmpty else { return }
        await MainActor.run {
            AudioPlayerService.shared.addPlayNext(songs)
            currentToast = ShelveToast(message: String(localized: "plays_next"))
        }
    }

    private func downloadRecap(_ entry: RecapRegistryRecord) async {
        guard let loaded = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
              let songs = loaded.songs, !songs.isEmpty else { return }
        let missing = songs.filter { !downloadStore.isDownloaded(songId: $0.id) }
        if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
        let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
        let period = RecapPeriod(
            type: type,
            start: Date(timeIntervalSince1970: entry.periodStart),
            end: Date(timeIntervalSince1970: entry.periodEnd)
        )
        downloadStore.addOfflinePlaylist(
            entry.playlistId,
            name: period.playlistName,
            songIds: songs.map(\.id)
        )
        await MainActor.run {
            currentToast = ShelveToast(message: String(localized: "download_started"))
        }
    }

    private func deleteRecapDownloads(_ entry: RecapRegistryRecord) {
        let pid = entry.playlistId
        downloadStore.removeOfflinePlaylist(pid)
        Task {
            if let loaded = await libraryStore.loadPlaylistDetail(id: pid),
               let songs = loaded.songs {
                for song in songs {
                    downloadStore.deleteSong(song.id)
                }
            }
        }
    }
}

// MARK: - PeriodType helpers

extension RecapPeriod.PeriodType {
    var label: String {
        switch self {
        case .week:  return String(localized: "weekly")
        case .month: return String(localized: "monthly")
        case .year:  return String(localized: "yearly")
        }
    }

    var icon: String {
        switch self {
        case .week:  return "calendar"
        case .month: return "calendar.badge.clock"
        case .year:  return "calendar.badge.checkmark"
        }
    }
}
