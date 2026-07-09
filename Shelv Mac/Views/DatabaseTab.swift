import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DatabaseTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var recapStore = RecapStore.shared
    @StateObject private var ckStatus = CloudKitSyncService.shared.status
    @Environment(\.themeColor) private var themeColor

    @AppStorage("mixUseDatabase") private var mixUseDatabase = false

    @State private var totalPlays: Int = 0
    @State private var isPreparingExport = false
    @State private var exportError: String?
    @State private var showPlayLog = false
    @State private var showDBLog = false
    @State private var showResetConfirm = false
    @State private var showCleanupConfirm = false
    @State private var isCleaningDatabase = false
    @State private var cleanupChecked = 0
    @State private var cleanupTotal = 0
    @State private var cleanupResult: String?
    @State private var cleanupDone = false

    var body: some View {
        Form {
            Section(String(localized: "overview")) {
                LabeledContent(String(localized: "total_plays")) {
                    Text("\(totalPlays)").foregroundStyle(.secondary).monospacedDigit()
                }
                Toggle(String(localized: "mixes_from_database"), isOn: $mixUseDatabase)
                if mixUseDatabase {
                    Text(String(localized: "mixes_from_database_footer"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "database")) {
                Button {
                    guard !isPreparingExport else { return }
                    isPreparingExport = true
                    Task {
                        defer { isPreparingExport = false }
                        do {
                            let url = try await recapStore.exportBackupURL()
                            runExportSavePanel(sourceURL: url)
                        } catch {
                            exportError = error.localizedDescription
                        }
                    }
                } label: {
                    if isPreparingExport {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(String(localized: "export_database"), systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isPreparingExport)

                Button {
                    runImportOpenPanel()
                } label: {
                    Label(String(localized: "import_database"), systemImage: "square.and.arrow.down")
                }
            }

            Section(String(localized: "logs")) {
                Button { showPlayLog = true } label: {
                    Label(String(localized: "recent_plays"), systemImage: "list.bullet.clipboard")
                }
                Button { showDBLog = true } label: {
                    Label(String(localized: "database_errors"), systemImage: "tablecells")
                }
            }

            Section(String(localized: "destructive_actions")) {
                Button(role: .destructive) {
                    showCleanupConfirm = true
                } label: {
                    if isCleaningDatabase {
                        HStack {
                            ProgressView().controlSize(.small).tint(.red)
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
                    Label(String(localized: "reset_local_database"), systemImage: "arrow.counterclockwise")
                        .foregroundStyle(.red)
                }

            }
        }
        .formStyle(.grouped)
        .padding()
        .task(id: appState.serverStore.activeServerID) { await refreshTotalPlays() }
        .onChange(of: ckStatus.lastSyncDate) { _, _ in
            Task { await refreshTotalPlays() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
            Task { await refreshTotalPlays() }
        }
        .sheet(isPresented: $showPlayLog) {
            if let sid = appState.serverStore.activeServer?.stableId {
                RecapPlayLogView(serverId: sid)
            }
        }
        .sheet(isPresented: $showDBLog) {
            RecapDBLogView()
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
        .confirmationDialog(
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
        .confirmationDialog(
            String(localized: "reset_local_database_2"),
            isPresented: $showResetConfirm
        ) {
            Button(String(localized: "reset"), role: .destructive) {
                guard let sid = appState.serverStore.activeServer?.stableId else { return }
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
    }

    @MainActor
    private func refreshTotalPlays() async {
        guard let sid = appState.serverStore.activeServer?.stableId else {
            totalPlays = 0
            return
        }
        let count = await PlayLogService.shared.logCount(serverId: sid)
        totalPlays = count
    }

    @MainActor
    private func performDatabaseCleanup() async {
        guard let sid = appState.serverStore.activeServer?.stableId else { return }
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
            await refreshTotalPlays()
            cleanupDone = true
            cleanupResult = String(localized: "no_dead_entries_found")
            return
        }

        let uuids = await PlayLogService.shared.uuids(forSongIds: dead, serverId: sid)
        let removed = await PlayLogService.shared.deletePlays(forSongIds: dead, serverId: sid)
        if !uuids.isEmpty {
            await CloudKitSyncService.shared.deletePlayEvents(uuids: uuids, force: true)
        }
        await refreshTotalPlays()
        cleanupDone = true
        cleanupResult = String(format: String(localized: "cleanup_removed_format"), dead.count, removed)
    }

    private func runExportSavePanel(sourceURL: URL) {
        let panel = NSSavePanel()
        panel.title = String(localized: "save_recap_database")
        panel.nameFieldStringValue = "shelv_recap_export.db"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func runImportOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "import_recap_database")
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let sid = appState.serverStore.activeServer?.stableId else { return }
        Task { await recapStore.importDatabase(from: url, serverId: sid) }
    }
}

struct ICloudSyncTab: View {
    @EnvironmentObject var serverStore: ServerStore
    @StateObject private var ckStatus = CloudKitSyncService.shared.status
    @Environment(\.themeColor) private var themeColor

    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("iCloudSyncPlayHistoryEnabled") private var playHistorySyncEnabled = true
    @AppStorage("iCloudSyncRecapEnabled") private var recapSyncEnabled = true
    @AppStorage("iCloudSyncLyricsServerEnabled") private var lyricsServerSyncEnabled = true
    @AppStorage("iCloudSyncRadioStationsEnabled") private var radioStationsSyncEnabled = true
    @AppStorage("iCloudSyncUICustomizationsEnabled") private var uiCustomizationsSyncEnabled = true

    @State private var isSyncingManually = false
    @State private var showSyncLog = false
    @State private var showIcloudResetConfirm = false
    @State private var isIcloudResetting = false

    var body: some View {
        Form {
            Section(String(localized: "icloud_sync")) {
                Toggle(String(localized: "enable_icloud_sync"), isOn: $iCloudSyncEnabled)
                    .onChange(of: iCloudSyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncEnabledChange() }
                    }

                if iCloudSyncEnabled {
                    if !ckStatus.accountAvailable {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "no_icloud_account"))
                                Text(String(localized: "use_exportimport_as_backup_instead"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "icloud.slash")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        LabeledContent(String(localized: "last_sync_2")) {
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
                        LabeledContent {
                            Text(syncStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label(String(localized: "sync_status"), systemImage: "waveform.path.ecg")
                        }
                        Button {
                            guard !isSyncingManually else { return }
                            isSyncingManually = true
                            Task {
                                defer { isSyncingManually = false }
                                await CloudKitSyncService.shared.syncNow()
                            }
                        } label: {
                            Label {
                                Text(String(localized: "sync_now"))
                            } icon: {
                                if isSyncingManually {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                            }
                        }
                        .disabled(isSyncingManually)
                    }
                }
            }

            if iCloudSyncEnabled {
                Section(String(localized: "what_to_sync")) {
                    Toggle(String(localized: "play_history"), isOn: $playHistorySyncEnabled)
                        .onChange(of: playHistorySyncEnabled) { _, _ in
                            Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                        }
                    Toggle(String(localized: "recap"), isOn: $recapSyncEnabled)
                        .onChange(of: recapSyncEnabled) { _, _ in
                            Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                        }
                    Toggle(String(localized: "lyrics_server"), isOn: $lyricsServerSyncEnabled)
                        .onChange(of: lyricsServerSyncEnabled) { _, _ in
                            Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                        }
                    Toggle(String(localized: "radio_stations"), isOn: $radioStationsSyncEnabled)
                        .onChange(of: radioStationsSyncEnabled) { _, _ in
                            Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                        }
                    Toggle(String(localized: "ui_customizations"), isOn: $uiCustomizationsSyncEnabled)
                        .onChange(of: uiCustomizationsSyncEnabled) { _, _ in
                            Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                        }
                }

                Section(String(localized: "logs")) {
                    Button { showSyncLog = true } label: {
                        Label(String(localized: "sync_log"), systemImage: "doc.text")
                    }
                }

                Section(String(localized: "destructive_actions")) {
                    Button(role: .destructive) {
                        showIcloudResetConfirm = true
                    } label: {
                        if isIcloudResetting {
                            HStack {
                                ProgressView().controlSize(.small).tint(.red)
                                Text(String(localized: "deleting")).foregroundStyle(.red)
                            }
                        } else {
                            Label(String(localized: "delete_icloud_data"), systemImage: "icloud.slash")
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(isIcloudResetting || serverStore.activeServer == nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showSyncLog) {
            RecapSyncLogView()
        }
        .confirmationDialog(
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
