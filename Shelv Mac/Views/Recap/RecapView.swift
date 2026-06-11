import SwiftUI

struct RecapView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @StateObject private var recapStore = RecapStore.shared
    @Environment(\.themeColor) private var themeColor
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("recapWeeklyEnabled") private var weeklyEnabled = true
    @AppStorage("recapMonthlyEnabled") private var monthlyEnabled = true
    @AppStorage("recapYearlyEnabled") private var yearlyEnabled = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    @State private var segment: RecapPeriod.PeriodType = .week
    @State private var entryToDelete: RecapRegistryRecord?
    @State private var path = NavigationPath()

    private var enabledTypes: [RecapPeriod.PeriodType] {
        var types: [RecapPeriod.PeriodType] = []
        if weeklyEnabled  { types.append(.week) }
        if monthlyEnabled { types.append(.month) }
        if yearlyEnabled  { types.append(.year) }
        return types
    }

    private var filteredEntries: [RecapRegistryRecord] {
        let typed = recapStore.entries.filter { $0.periodType == segment.rawValue }
        return offlineMode.isOffline
            ? typed.filter { downloadStore.downloadedPlaylistIds.contains($0.playlistId) }
            : typed
    }

    var body: some View {
        NavigationStack(path: $path) {
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
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                        Divider()
                    }

                    if filteredEntries.isEmpty {
                        emptyStateView(
                            icon: "clock",
                            message: String(localized: "no_recap_generated_yet_for_this_period")
                        )
                    } else {
                        List {
                            ForEach(filteredEntries, id: \.playlistId) { entry in
                                Button {
                                    path.append(entry)
                                } label: {
                                    recapRow(entry)
                                }
                                .buttonStyle(.plain)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .contextMenu {
                                    Button(String(localized: "play")) {
                                        Task {
                                            if let detail = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
                                               let songs = detail.songs, !songs.isEmpty {
                                                AudioPlayerService.shared.play(songs: songs)
                                            } else {
                                                NotificationCenter.default.post(name: .showToast, object: String(localized: "action_failed"))
                                            }
                                        }
                                    }
                                    Button(String(localized: "shuffle")) {
                                        Task {
                                            if let detail = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
                                               let songs = detail.songs, !songs.isEmpty {
                                                AudioPlayerService.shared.playShuffled(songs: songs)
                                            } else {
                                                NotificationCenter.default.post(name: .showToast, object: String(localized: "action_failed"))
                                            }
                                        }
                                    }
                                    Divider()
                                    Button(String(localized: "play_next")) {
                                        Task {
                                            if let detail = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
                                               let songs = detail.songs, !songs.isEmpty {
                                                AudioPlayerService.shared.addPlayNext(songs)
                                                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                                            } else {
                                                NotificationCenter.default.post(name: .showToast, object: String(localized: "action_failed"))
                                            }
                                        }
                                    }
                                    Button(String(localized: "add_to_queue")) {
                                        Task {
                                            if let detail = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
                                               let songs = detail.songs, !songs.isEmpty {
                                                AudioPlayerService.shared.addToUserQueue(songs)
                                                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                                            } else {
                                                NotificationCenter.default.post(name: .showToast, object: String(localized: "action_failed"))
                                            }
                                        }
                                    }
                                    if enableDownloads {
                                        Divider()
                                        let recapType = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
                                        let recapPeriod = RecapPeriod(type: recapType, start: Date(timeIntervalSince1970: entry.periodStart), end: Date(timeIntervalSince1970: entry.periodEnd))
                                        let isMarked = downloadStore.downloadedPlaylistIds.contains(entry.playlistId)
                                        if isMarked {
                                            Button(role: .destructive) {
                                                Task {
                                                    if let detail = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
                                                       let songs = detail.songs {
                                                        for song in songs {
                                                            downloadStore.deleteSong(song.id)
                                                        }
                                                    }
                                                    downloadStore.unmarkPlaylistDownloaded(id: entry.playlistId)
                                                }
                                            } label: {
                                                Label(String(localized: "delete_downloads"), systemImage: "arrow.down.circle")
                                            }
                                        } else if !offlineMode.isOffline {
                                            Button(String(localized: "download")) {
                                                Task {
                                                    if let detail = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
                                                       let songs = detail.songs {
                                                        let missing = songs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                                                        if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                                                        downloadStore.markPlaylistDownloaded(id: entry.playlistId, name: recapPeriod.playlistName, songIds: songs.map(\.id))
                                                        NotificationCenter.default.post(name: .showToast, object: String(localized: "download_started"))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        entryToDelete = entry
                                    } label: {
                                        Label(String(localized: "delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(localized: "recap"))
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            guard let sid = appState.serverStore.activeServer?.stableId else { return }
                            async let cleanup:   Void = recapStore.refreshWithCleanup(serverId: sid)
                            async let sync:      Void = CloudKitSyncService.shared.syncNow()
                            async let playlists: Void = libraryStore.loadPlaylists()
                            _ = await (cleanup, sync, playlists)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(String(localized: "reload"))
                }
            }
            .navigationDestination(for: RecapRegistryRecord.self) { entry in
                if let sid = appState.serverStore.activeServer?.stableId {
                    RecapDetailView(entry: entry, serverId: sid)
                        .environmentObject(appState)
                }
            }
        }
        .confirmationDialog(
            String(localized: "delete_recap_2"),
            isPresented: Binding(get: { entryToDelete != nil }, set: { if !$0 { entryToDelete = nil } }),
            presenting: entryToDelete
        ) { entry in
            Button(String(localized: "delete"), role: .destructive) {
                guard let sid = appState.serverStore.activeServer?.stableId else { return }
                Task {
                    do {
                        try await recapStore.deleteEntry(playlistId: entry.playlistId, serverId: sid)
                    } catch {
                        if !(error is CancellationError) {
                            NotificationCenter.default.post(name: .showToast, object: String(localized: "could_not_delete_recap"))
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
        .onAppear {
            if let first = enabledTypes.first, !enabledTypes.contains(segment) {
                segment = first
            }
        }
        .task(id: appState.serverStore.activeServerID) {
            guard let sid = appState.serverStore.activeServer?.stableId else { return }
            async let cleanup:   Void = recapStore.refreshWithCleanup(serverId: sid)
            async let playlists: Void = libraryStore.loadPlaylists()
            _ = await (cleanup, playlists)
        }
    }

    private func recapRow(_ entry: RecapRegistryRecord) -> some View {
        let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
        let period = RecapPeriod(
            type: type,
            start: Date(timeIntervalSince1970: entry.periodStart),
            end: Date(timeIntervalSince1970: entry.periodEnd)
        )
        let isMissing = !libraryStore.playlists.isEmpty
            && !libraryStore.playlists.contains { $0.id == entry.playlistId }
        let iconColor: Color = isMissing ? .orange : themeColor
        let iconName = isMissing ? "exclamationmark.triangle.fill" : type.icon
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.12))
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)
            }
            .frame(width: 48, height: 48)

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
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .contentShape(Rectangle())
    }

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
}

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
