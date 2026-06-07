import SwiftUI
import UniformTypeIdentifiers

private struct ShareableFileWrap: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DatabaseSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var recapStore: RecapStore
    @EnvironmentObject var ckStatus: CloudKitSyncStatus
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true
    @AppStorage("mixUseDatabase") private var mixUseDatabase = false

    @State private var totalPlays: Int = 0
    @State private var showImportFilePicker = false
    @State private var showSyncReport = false
    @State private var isSyncingManually = false
    @State private var isPreparingExport = false
    @State private var exportItem: ShareableFileWrap?
    @State private var exportError: String?
    @State private var showResetConfirm = false
    @State private var showIcloudResetConfirm = false
    @State private var showFullResetConfirm = false
    @State private var isIcloudResetting = false
    @State private var isFullResetting = false
    @State private var showCleanupConfirm = false
    @State private var isCleaningDatabase = false
    @State private var cleanupChecked = 0
    @State private var cleanupTotal = 0
    @State private var cleanupResult: String?

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            // MARK: Overview
            Section(String(localized: "overview")) {
                HStack {
                    Label { Text(String(localized: "total_plays")) } icon: {
                        Image(systemName: "music.note.list").foregroundStyle(accentColor)
                    }
                    Spacer()
                    Text("\(totalPlays)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Toggle(isOn: $mixUseDatabase) {
                    Label { Text(String(localized: "mixes_from_database")) } icon: {
                        Image(systemName: "cylinder.split.1x2").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                if mixUseDatabase {
                    Text(String(localized: "mixes_from_database_footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Datenbank
            Section(String(localized: "database")) {
                Button {
                    guard !isPreparingExport else { return }
                    isPreparingExport = true
                    Task {
                        defer { isPreparingExport = false }
                        do {
                            let url = try await recapStore.exportBackupURL()
                            exportItem = ShareableFileWrap(url: url)
                        } catch {
                            exportError = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        Label { Text(String(localized: "export_database")) } icon: {
                            Image(systemName: "square.and.arrow.up").foregroundStyle(accentColor)
                        }
                        if isPreparingExport { Spacer(); ProgressView() }
                    }
                }
                .disabled(isPreparingExport)

                Button {
                    showImportFilePicker = true
                } label: {
                    Label { Text(String(localized: "import_database")) } icon: {
                        Image(systemName: "square.and.arrow.down").foregroundStyle(accentColor)
                    }
                }
            }

            // MARK: iCloud Sync
            Section(String(localized: "icloud_sync")) {
                if !ckStatus.accountAvailable {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud.slash")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "no_icloud_account"))
                                .font(.subheadline)
                            Text(String(localized: "use_exportimport_as_backup_instead"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    Toggle(isOn: $iCloudSyncEnabled) {
                        Label { Text(String(localized: "icloud_sync")) } icon: {
                            Image(systemName: "icloud").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .onChange(of: iCloudSyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncEnabledChange() }
                    }

                    if !iCloudSyncEnabled {
                        Text(String(localized: "data_stays_local_multiple_devices_may_create_dupli"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label { Text(String(localized: "last_sync")) } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accentColor)
                        }
                        Spacer()
                        if let date = ckStatus.lastSyncDate {
                            Text(date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "never"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Label { Text(String(localized: "pending_uploads")) } icon: {
                            Image(systemName: "icloud.and.arrow.up").foregroundStyle(accentColor)
                        }
                        Spacer()
                        Text(ckStatus.pendingUploads > 0 ? "\(ckStatus.pendingUploads)" : "—")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }

                    Button {
                        guard !isSyncingManually else { return }
                        isSyncingManually = true
                        Task {
                            defer { isSyncingManually = false }
                            await CloudKitSyncService.shared.syncNow()
                        }
                    } label: {
                        HStack {
                            Label { Text(String(localized: "sync_now")) } icon: {
                                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accentColor)
                            }
                            if isSyncingManually { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isSyncingManually)
                }
            }

            // MARK: Logs
            if let sid = serverStore.activeServer?.stableId {
                Section(String(localized: "logs")) {
                    NavigationLink(destination: RecapPlayLogView(serverId: sid)) {
                        Label { Text(String(localized: "recent_plays")) } icon: {
                            Image(systemName: "list.bullet.clipboard").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination:
                        RecapSyncLogView()
                            .environmentObject(ckStatus)
                    ) {
                        Label { Text(String(localized: "sync_log")) } icon: {
                            Image(systemName: "doc.text").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination: RecapDBLogView()) {
                        Label { Text(String(localized: "database_errors")) } icon: {
                            Image(systemName: "exclamationmark.octagon").foregroundStyle(accentColor)
                        }
                    }
                }

                // MARK: Destructive Actions
                Section(String(localized: "destructive_actions")) {
                    Button(role: .destructive) {
                        showCleanupConfirm = true
                    } label: {
                        if isCleaningDatabase {
                            HStack {
                                ProgressView().tint(.red)
                                Text(cleanupTotal > 0
                                     ? String(format: String(localized: "checking_count_format"), cleanupChecked, cleanupTotal)
                                     : String(localized: "cleaning_up"))
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Label(String(localized: "database_cleanup"), systemImage: "trash.slash")
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(isCleaningDatabase)

                    if let result = cleanupResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label(
                            String(localized: "reset_local_database"),
                            systemImage: "arrow.counterclockwise"
                        )
                        .foregroundStyle(.red)
                    }

                    Button(role: .destructive) {
                        showIcloudResetConfirm = true
                    } label: {
                        if isIcloudResetting {
                            HStack {
                                ProgressView().tint(.red)
                                Text(String(localized: "deleting")).foregroundStyle(.red)
                            }
                        } else {
                            Label(
                                String(localized: "delete_icloud_data"),
                                systemImage: "icloud.slash"
                            )
                            .foregroundStyle(.red)
                        }
                    }
                    .disabled(isIcloudResetting)

                    Button(role: .destructive) {
                        showFullResetConfirm = true
                    } label: {
                        if isFullResetting {
                            HStack {
                                ProgressView().tint(.red)
                                Text(String(localized: "deleting")).foregroundStyle(.red)
                            }
                        } else {
                            Label(
                                String(localized: "delete_everything"),
                                systemImage: "trash.slash"
                            )
                            .foregroundStyle(.red)
                        }
                    }
                    .disabled(isFullResetting)
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .navigationTitle(String(localized: "database"))
        .sheet(item: $exportItem) { file in
            ActivityView(items: [file.url])
        }
        .alert(
            String(localized: "export_failed"),
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } }),
            presenting: exportError
        ) { _ in
            Button(String(localized: "ok"), role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .fileImporter(isPresented: $showImportFilePicker, allowedContentTypes: [.item]) { result in
            guard let url = try? result.get(),
                  let sid = serverStore.activeServer?.stableId else { return }
            Task { await recapStore.importDatabase(from: url, serverId: sid) }
        }
        .sheet(isPresented: $showSyncReport) {
            syncReportSheet
        }
        .onChange(of: recapStore.showSyncReport) { _, show in
            if show { showSyncReport = true; recapStore.showSyncReport = false }
        }
        .alert(
            String(localized: "reset_local_database_2"),
            isPresented: $showResetConfirm
        ) {
            Button(String(localized: "reset"), role: .destructive) {
                guard let sid = serverStore.activeServer?.stableId else { return }
                Task {
                    await PlayLogService.shared.resetLog(serverId: sid)
                    await PlayLogService.shared.resetRegistry(serverId: sid)
                    await CloudKitSyncService.shared.resetChangeToken()
                    await recapStore.loadEntries(serverId: sid)
                    NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
                    await refreshTotalPlays()
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "clears_the_local_cache_only_icloud_and_navidrome_s"))
        }
        .alert(
            String(localized: "delete_icloud_data_2"),
            isPresented: $showIcloudResetConfirm
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                Task { await performIcloudReset() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "all_icloud_records_for_this_server_will_be_deleted"))
        }
        .alert(
            String(localized: "delete_everything_2"),
            isPresented: $showFullResetConfirm
        ) {
            Button(String(localized: "delete_everything"), role: .destructive) {
                Task { await performFullReset() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "all_recap_playlists_on_navidrome_local_play_logs_a"))
        }
        .alert(
            String(localized: "database_cleanup_2"),
            isPresented: $showCleanupConfirm
        ) {
            Button(String(localized: "clean_up"), role: .destructive) {
                Task { await performDatabaseCleanup() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "checks_every_song_against_the_server_and_permanent"))
        }
        .task(id: serverStore.activeServerID) { await refreshTotalPlays() }
        .onChange(of: ckStatus.lastSyncDate) { _, _ in
            Task { await refreshTotalPlays() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
            Task { await refreshTotalPlays() }
        }
    }

    private func refreshTotalPlays() async {
        guard let sid = serverStore.activeServer?.stableId else { totalPlays = 0; return }
        totalPlays = await PlayLogService.shared.logCount(serverId: sid)
    }

    /// Prüft jeden im Log vorkommenden Song serverseitig. Songs, die der Server definitiv nicht
    /// mehr kennt (Error 70 / „not found"), werden lokal UND in iCloud gelöscht. Netzwerkfehler
    /// löschen nie — solche IDs bleiben unangetastet und werden beim nächsten Lauf erneut geprüft.
    @MainActor
    private func performDatabaseCleanup() async {
        guard let sid = serverStore.activeServer?.stableId else { return }
        isCleaningDatabase = true
        cleanupResult = nil
        cleanupChecked = 0
        cleanupTotal = 0
        defer {
            isCleaningDatabase = false
            cleanupChecked = 0
            cleanupTotal = 0
        }

        let ids = await PlayLogService.shared.distinctSongIds(serverId: sid)
        guard !ids.isEmpty else {
            cleanupResult = String(localized: "no_entries_to_check")
            return
        }
        cleanupTotal = ids.count

        var dead: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = ids.makeIterator()
            let maxConcurrent = 6
            var inFlight = 0
            while inFlight < maxConcurrent, let id = iterator.next() {
                inFlight += 1
                group.addTask { (id, await songIsDead(id: id)) }
            }
            for await (id, isDead) in group {
                cleanupChecked += 1
                if isDead { dead.append(id) }
                if let next = iterator.next() {
                    group.addTask { (next, await songIsDead(id: next)) }
                }
            }
        }

        guard !dead.isEmpty else {
            cleanupResult = String(localized: "no_dead_entries_found")
            return
        }

        let uuids   = await PlayLogService.shared.uuids(forSongIds: dead, serverId: sid)
        let removed = await PlayLogService.shared.deletePlays(forSongIds: dead, serverId: sid)
        if !uuids.isEmpty {
            await CloudKitSyncService.shared.deletePlayEvents(uuids: uuids, force: true)
        }
        await refreshTotalPlays()
        cleanupResult = String(format: String(localized: "cleanup_removed_format"), dead.count, removed)
    }

    private func performIcloudReset() async {
        guard let sid = serverStore.activeServer?.stableId else { return }
        isIcloudResetting = true
        defer { isIcloudResetting = false }
        await CloudKitSyncService.shared.deleteZone(force: true)
        await PlayLogService.shared.markServerUnsyncedForReUpload(serverId: sid)
        await CloudKitSyncService.shared.updatePendingCounts()
    }

    private func performFullReset() async {
        guard let sid = serverStore.activeServer?.stableId else { return }
        isFullResetting = true
        defer { isFullResetting = false }
        let registry = await PlayLogService.shared.allRegistryEntries(serverId: sid)
        for entry in registry {
            try? await SubsonicAPIService.shared.deletePlaylist(id: entry.playlistId)
        }
        await CloudKitSyncService.shared.deleteZone(force: true)
        await PlayLogService.shared.resetLog(serverId: sid)
        await PlayLogService.shared.resetRegistry(serverId: sid)
        await PlayLogService.shared.removeScrobbles(serverId: sid)
        await CloudKitSyncService.shared.resetChangeToken()
        await CloudKitSyncService.shared.updatePendingCounts()
        await recapStore.loadEntries(serverId: sid)
        await refreshTotalPlays()
    }

    private var syncReportSheet: some View {
        NavigationStack {
            List(recapStore.syncReports) { report in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: report.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(report.isError ? .red : accentColor)
                    Text(report.message).font(.subheadline)
                }
            }
            .navigationTitle(String(localized: "recap_sync"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { showSyncReport = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(24)
    }
}

/// Fragt einen Song beim Server ab. `true` nur, wenn der Server ihn definitiv nicht kennt
/// (Subsonic-Error 70 oder „not found"). Netzwerk-/sonstige Fehler → `false` (nicht löschen).
/// Freie Funktion (nicht actor-isoliert) → die Prüfungen laufen echt nebenläufig.
private func songIsDead(id: String) async -> Bool {
    do {
        _ = try await SubsonicAPIService.shared.getSong(id: id)
        return false
    } catch SubsonicAPIError.apiError(let code, let message) {
        if code == 70 { return true }
        if code == 0, (message ?? "").range(of: "not found", options: .caseInsensitive) != nil { return true }
        return false
    } catch {
        return false
    }
}
