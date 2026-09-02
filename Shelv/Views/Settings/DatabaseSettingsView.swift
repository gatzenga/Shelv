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
    @ObservedObject private var backupStore = PlayLogBackupStore.shared
    @EnvironmentObject var ckStatus: CloudKitSyncStatus
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("mixUseDatabase") private var mixUseDatabase = false

    @State private var totalPlays: Int = 0
    @State private var showImportFilePicker = false
    @State private var showSyncReport = false
    @State private var isPreparingExport = false
    @State private var exportItem: ShareableFileWrap?
    @State private var exportError: String?
    @State private var showResetConfirm = false
    @State private var showCleanupConfirm = false
    @State private var isCleaningDatabase = false
    @State private var cleanupChecked = 0
    @State private var cleanupTotal = 0
    @State private var cleanupResult: String?
    @State private var cleanupDone = false

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
                            let url = try await backupStore.exportBackupURL()
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

            // MARK: Logs
            if let sid = serverStore.activeServer?.stableId {
                Section(String(localized: "logs")) {
                    NavigationLink(destination: PlayLogView(serverId: sid)) {
                        Label { Text(String(localized: "recent_plays")) } icon: {
                            Image(systemName: "list.bullet.clipboard").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination: DatabaseErrorLogView()) {
                        Label { Text(String(localized: "database_errors")) } icon: {
                            Image(systemName: "tablecells").foregroundStyle(accentColor)
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

                    if cleanupDone {
                        Label(String(localized: "cleanup_complete"), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
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
            Task { await backupStore.importDatabase(from: url, serverId: sid) }
        }
        .sheet(isPresented: $showSyncReport) {
            syncReportSheet
        }
        .onChange(of: backupStore.showReport) { _, show in
            if show { showSyncReport = true; backupStore.showReport = false }
        }
        .alert(
            String(localized: "reset_local_database_2"),
            isPresented: $showResetConfirm
        ) {
            Button(String(localized: "reset"), role: .destructive) {
                guard let sid = serverStore.activeServer?.stableId else { return }
                Task {
                    await PlayLogService.shared.resetLog(serverId: sid)
                    await CloudKitSyncService.shared.resetChangeToken()
                    await refreshTotalPlays()
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "clears_the_local_cache_only_icloud_and_navidrome_s"))
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
    }

    @MainActor
    private func refreshTotalPlays() async {
        guard let sid = serverStore.activeServer?.stableId else { totalPlays = 0; return }
        let count = await PlayLogService.shared.logCount(serverId: sid)
        totalPlays = count
    }

    /// Prüft jeden im Log vorkommenden Song serverseitig. Löst die ID auf, werden Titel/Artist/
    /// Album aufgefrischt; löst nur ein Titel+Artist+Album-Treffer auf, wird die ID repariert.
    /// Nur wenn beides scheitert, wird die Zeile lokal UND in iCloud gelöscht. Netzwerkfehler und
    /// mehrdeutige Treffer lassen Zeilen unangetastet — sie werden beim nächsten Lauf erneut geprüft.
    @MainActor
    private func performDatabaseCleanup() async {
        guard let sid = serverStore.activeServer?.stableId else { return }
        isCleaningDatabase = true
        cleanupResult = nil
        cleanupDone = false
        cleanupChecked = 0
        cleanupTotal = 0
        defer {
            isCleaningDatabase = false
            cleanupChecked = 0
            cleanupTotal = 0
        }

        guard let requestContext = try? await SubsonicAPIService.shared.resolvedActiveRequestContext(
            expectedServerId: sid
        ) else {
            cleanupResult = String(localized: "no_entries_to_check")
            return
        }

        let summary = await CloudKitSyncService.shared.reconcilePlayLog(
            serverId: sid,
            requestContext: requestContext
        ) { checked, total in
            cleanupChecked = checked
            cleanupTotal = total
        }

        guard summary.checked > 0 else {
            cleanupResult = String(localized: "no_entries_to_check")
            return
        }

        await refreshTotalPlays()
        cleanupDone = true
        cleanupResult = String(
            format: String(localized: "cleanup_summary_format"),
            summary.refreshed,
            summary.repaired,
            summary.deletedSongs,
            summary.removedRows
        )
    }

    private var syncReportSheet: some View {
        NavigationStack {
            List(backupStore.reports) { report in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: report.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(report.isError ? .red : accentColor)
                    Text(report.message).font(.subheadline)
                }
            }
            .navigationTitle(String(localized: "database"))
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

struct ICloudSyncSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var ckStatus: CloudKitSyncStatus
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("iCloudSyncPlayHistoryEnabled") private var playHistorySyncEnabled = true
    @AppStorage("iCloudSyncLyricsServerEnabled") private var lyricsServerSyncEnabled = true
    @AppStorage("iCloudSyncRadioStationsEnabled") private var radioStationsSyncEnabled = true
    @AppStorage("iCloudSyncUICustomizationsEnabled") private var uiCustomizationsSyncEnabled = true

    @State private var isSyncingManually = false
    @State private var showIcloudResetConfirm = false
    @State private var isIcloudResetting = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
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

                    if iCloudSyncEnabled {
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
                            Label { Text(String(localized: "sync_status")) } icon: {
                                Image(systemName: "waveform.path.ecg").foregroundStyle(accentColor)
                            }
                            Spacer()
                            Text(syncStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            }

            if iCloudSyncEnabled {
                Section(String(localized: "what_to_sync")) {
                    Toggle(isOn: $playHistorySyncEnabled) {
                        Label { Text(String(localized: "play_history")) } icon: {
                            Image(systemName: "music.note.list").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .onChange(of: playHistorySyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                    }

                    Toggle(isOn: $lyricsServerSyncEnabled) {
                        Label { Text(String(localized: "lyrics_server")) } icon: {
                            Image(systemName: "text.bubble").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .onChange(of: lyricsServerSyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                    }

                    Toggle(isOn: $radioStationsSyncEnabled) {
                        Label { Text(String(localized: "radio_stations")) } icon: {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .onChange(of: radioStationsSyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                    }

                    Toggle(isOn: $uiCustomizationsSyncEnabled) {
                        Label { Text(String(localized: "ui_customizations")) } icon: {
                            Image(systemName: "slider.horizontal.2.square").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .onChange(of: uiCustomizationsSyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                    }
                }

                Section(String(localized: "logs")) {
                    NavigationLink(destination:
                        SyncLogView()
                            .environmentObject(ckStatus)
                    ) {
                        Label { Text(String(localized: "sync_log")) } icon: {
                            Image(systemName: "doc.text").foregroundStyle(accentColor)
                        }
                    }
                }

                Section(String(localized: "destructive_actions")) {
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
                    .disabled(isIcloudResetting || serverStore.activeServer == nil)
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .navigationTitle("iCloud")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    private var syncStatusText: String {
        if let message = ckStatus.currentMessage, !message.isEmpty {
            return message
        }
        if ckStatus.isSyncing {
            return String(localized: "sync_status_syncing")
        }
        if ckStatus.pendingUploads > 0 {
            return String(format: String(localized: "sync_status_pending_format"), ckStatus.pendingUploads)
        }
        return String(localized: "sync_status_idle")
    }

    @MainActor
    private func performIcloudReset() async {
        guard let sid = serverStore.activeServer?.stableId else { return }
        isIcloudResetting = true
        defer { isIcloudResetting = false }
        await CloudKitSyncService.shared.deleteZone(force: true)
        await PlayLogService.shared.markServerUnsyncedForReUpload(serverId: sid)
        await CloudKitSyncService.shared.updatePendingCounts()
    }
}
