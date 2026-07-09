import SwiftUI

struct DatabaseSettingsView: View {
    @ObservedObject private var syncStatus = CloudKitSyncService.shared.status
    @AppStorage("mixUseDatabase") private var mixUseDatabase = false

    @State private var totalPlays = 0

    var body: some View {
        Form {
            Text(String(localized: "database"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            Section(String(localized: "overview")) {
                LabeledContent(String(localized: "total_plays"), value: "\(totalPlays)")
                Toggle(String(localized: "mixes_from_database"), isOn: $mixUseDatabase)
            }

            Section(String(localized: "logs")) {
                NavigationLink(String(localized: "database_errors")) {
                    DatabaseErrorLogView()
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .task { await refresh() }
        .onChange(of: syncStatus.lastSyncDate) { _, _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        if let sid = SubsonicAPIService.shared.activeServer?.stableId, !sid.isEmpty {
            totalPlays = await PlayLogService.shared.logCount(serverId: sid)
        }
    }
}

struct ICloudSyncSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @ObservedObject private var syncStatus = CloudKitSyncService.shared.status

    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("iCloudSyncPlayHistoryEnabled") private var playHistorySyncEnabled = true
    @AppStorage("iCloudSyncRecapEnabled") private var recapSyncEnabled = true
    @AppStorage("iCloudSyncLyricsServerEnabled") private var lyricsServerSyncEnabled = true
    @AppStorage("iCloudSyncRadioStationsEnabled") private var radioStationsSyncEnabled = true
    @State private var showIcloudResetConfirm = false
    @State private var isIcloudResetting = false

    var body: some View {
        Form {
            Text("iCloud")
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            Section(String(localized: "icloud_sync")) {
                Toggle(String(localized: "icloud_sync"), isOn: $iCloudSyncEnabled)
                    .onChange(of: iCloudSyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncEnabledChange() }
                    }

                if iCloudSyncEnabled {
                    if let date = syncStatus.lastSyncDate {
                        LabeledContent(
                            String(localized: "last_sync"),
                            value: date.formatted(date: .abbreviated, time: .shortened)
                        )
                    } else {
                        LabeledContent(String(localized: "last_sync"), value: String(localized: "never"))
                    }
                    LabeledContent {
                        Text(syncStatusText)
                    } label: {
                        Label(String(localized: "sync_status"), systemImage: "waveform.path.ecg")
                    }
                    Button(String(localized: "sync_now")) {
                        Task { await CloudKitSyncService.shared.syncNow() }
                    }
                    .disabled(syncStatus.isSyncing)
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
                }

                Section(String(localized: "logs")) {
                    NavigationLink(String(localized: "sync_log")) {
                        SyncLogView()
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
                            Label(String(localized: "delete_icloud_data"), systemImage: "icloud.slash")
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(isIcloudResetting || serverStore.activeServer == nil)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
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
        if let message = syncStatus.currentMessage, !message.isEmpty {
            return message
        }
        if syncStatus.isSyncing {
            return String(localized: "sync_status_syncing")
        }
        if syncStatus.pendingUploads > 0 {
            return String(format: String(localized: "sync_status_pending_format"), syncStatus.pendingUploads)
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

/// Live Sync-Log — beobachtet den CloudKit-Status, neue Sync-Zeilen erscheinen sofort.
private struct SyncLogView: View {
    @ObservedObject private var status = CloudKitSyncService.shared.status

    var body: some View {
        LogListView(title: String(localized: "sync_log"), entries: status.logEntries)
    }
}

/// Live Datenbank-Fehler-Log — beobachtet DBErrorLog, neue Fehler erscheinen sofort.
private struct DatabaseErrorLogView: View {
    @ObservedObject private var dbErrors = DBErrorLog.shared
    @State private var segment: LogTab = .playLog

    private enum LogTab: String, CaseIterable {
        case playLog, lyrics

        var title: String {
            switch self {
            case .playLog: return String(localized: "play_log_db")
            case .lyrics: return String(localized: "lyrics_db")
            }
        }
    }

    private var entries: [String] {
        switch segment {
        case .playLog: return dbErrors.playLogEntries
        case .lyrics: return dbErrors.lyricsEntries
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(LogTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 50)
            .padding(.top, 24)

            LogListView(title: String(localized: "database_errors"), entries: entries)
        }
    }
}
