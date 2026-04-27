import SwiftUI

struct RecapView: View {
    @EnvironmentObject var recapStore: RecapStore
    @EnvironmentObject var serverStore: ServerStore
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("recapWeeklyEnabled") private var weeklyEnabled = true
    @AppStorage("recapMonthlyEnabled") private var monthlyEnabled = true
    @AppStorage("recapYearlyEnabled") private var yearlyEnabled = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    @State private var segment: RecapPeriod.PeriodType = .week
    @State private var selectedEntry: RecapRegistryRecord?
    @State private var entryToDelete: RecapRegistryRecord?
    @State private var showDeleteConfirm = false
    @State private var currentToast: ShelveToast?

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
            ? typed.filter { downloadStore.offlinePlaylistIds.contains($0.playlistId) }
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
                        message: tr("Enable at least one period in Settings.", "Aktiviere mindestens eine Periode in den Einstellungen.")
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
                            message: tr("No recap generated yet for this period.", "Noch kein Recap für diese Periode erstellt.")
                        )
                    } else {
                        List {
                            ForEach(filteredEntries, id: \.playlistId) { entry in
                                Button { selectedEntry = entry } label: {
                                    recapRow(entry)
                                }
                                .buttonStyle(.plain)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        Task { await addRecapToQueue(entry) }
                                    } label: { Image(systemName: "text.badge.plus") }
                                    .tint(accentColor)
                                    Button {
                                        Task { await playRecapNext(entry) }
                                    } label: { Image(systemName: "text.insert") }
                                    .tint(.orange)
                                    if enableDownloads {
                                        recapDownloadSwipe(entry)
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        entryToDelete = entry
                                        showDeleteConfirm = true
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .refreshable {
                            guard let sid = serverStore.activeServer?.stableId else { return }
                            async let cleanup:  Void = recapStore.refreshWithCleanup(serverId: sid)
                            async let sync:     Void = CloudKitSyncService.shared.syncNow()
                            async let playlists: Void = libraryStore.loadPlaylists()
                            _ = await (cleanup, sync, playlists)
                        }
                        .navigationDestination(item: $selectedEntry) { entry in
                            recapDetail(entry)
                        }
                    }
                }
            }
            .navigationTitle(tr("Recap", "Recap"))
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
            tr("Delete Recap?", "Recap löschen?"),
            isPresented: $showDeleteConfirm,
            presenting: entryToDelete
        ) { entry in
            Button(tr("Delete", "Löschen"), role: .destructive) {
                guard let sid = serverStore.activeServer?.stableId else { return }
                Task { await recapStore.deleteEntry(playlistId: entry.playlistId, serverId: sid) }
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
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
                Text(tr("Top \(type.songLimit)", "Top \(type.songLimit)"))
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
            Text(tr("Recap is disabled", "Recap ist deaktiviert"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(tr("Enable Recap in Settings to start tracking your listening history.", "Aktiviere Recap in den Einstellungen, um dein Hörverhalten aufzuzeichnen."))
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
    private func recapDownloadSwipe(_ entry: RecapRegistryRecord) -> some View {
        if downloadStore.offlinePlaylistIds.contains(entry.playlistId) {
            Button(role: .destructive) {
                deleteRecapDownloads(entry)
            } label: { DeleteDownloadIcon() }
            .tint(.red)
        } else if !offlineMode.isOffline {
            Button {
                Task { await downloadRecap(entry) }
            } label: { Image(systemName: "arrow.down.circle") }
            .tint(accentColor)
        }
    }

    private func addRecapToQueue(_ entry: RecapRegistryRecord) async {
        guard let loaded = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
              let songs = loaded.songs, !songs.isEmpty else { return }
        await MainActor.run {
            AudioPlayerService.shared.addToQueue(songs)
            currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
        }
    }

    private func playRecapNext(_ entry: RecapRegistryRecord) async {
        guard let loaded = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
              let songs = loaded.songs, !songs.isEmpty else { return }
        await MainActor.run {
            AudioPlayerService.shared.addPlayNext(songs)
            currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
        }
    }

    private func downloadRecap(_ entry: RecapRegistryRecord) async {
        guard let loaded = await libraryStore.loadPlaylistDetail(id: entry.playlistId),
              let songs = loaded.songs, !songs.isEmpty else { return }
        let missing = songs.filter { !downloadStore.isDownloaded(songId: $0.id) }
        if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
        downloadStore.addOfflinePlaylist(entry.playlistId, songIds: songs.map(\.id))
        await MainActor.run {
            currentToast = ShelveToast(message: tr("Download started", "Download gestartet"))
        }
    }

    private func deleteRecapDownloads(_ entry: RecapRegistryRecord) {
        let pid = entry.playlistId
        downloadStore.removeOfflinePlaylist(pid)
        Task {
            if let loaded = await libraryStore.loadPlaylistDetail(id: pid),
               let songs = loaded.songs {
                for song in songs where downloadStore.isDownloaded(songId: song.id) {
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
        case .week:  return tr("Weekly", "Wöchentlich")
        case .month: return tr("Monthly", "Monatlich")
        case .year:  return tr("Yearly", "Jährlich")
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
