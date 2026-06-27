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
    @ObservedObject private var syncStatus = CloudKitSyncService.shared.status

    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true
    @AppStorage("iCloudSyncPlayHistoryEnabled") private var playHistorySyncEnabled = true
    @AppStorage("iCloudSyncRecapEnabled") private var recapSyncEnabled = true
    @AppStorage("iCloudSyncLyricsServerEnabled") private var lyricsServerSyncEnabled = false

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
                    LabeledContent(String(localized: "pending_uploads"), value: "\(syncStatus.pendingUploads)")
                    Button(String(localized: "sync_now")) {
                        Task { await CloudKitSyncService.shared.syncNow() }
                    }
                    .disabled(syncStatus.isSyncing)
                }
            }

            Section(String(localized: "what_to_sync")) {
                Toggle(String(localized: "play_history"), isOn: $playHistorySyncEnabled)
                    .disabled(!iCloudSyncEnabled)
                    .onChange(of: playHistorySyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                    }
                Toggle(String(localized: "recap"), isOn: $recapSyncEnabled)
                    .disabled(!iCloudSyncEnabled)
                    .onChange(of: recapSyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                    }
                Toggle(String(localized: "lyrics_server"), isOn: $lyricsServerSyncEnabled)
                    .disabled(!iCloudSyncEnabled)
                    .onChange(of: lyricsServerSyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncCategoryChange() }
                    }
            }

            Section(String(localized: "logs")) {
                NavigationLink(String(localized: "sync_log")) {
                    SyncLogView()
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
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
