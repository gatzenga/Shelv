import SwiftUI

struct DatabaseSettingsView: View {
    @ObservedObject private var syncStatus = CloudKitSyncService.shared.status
    @AppStorage("mixUseDatabase") private var mixUseDatabase = false
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true

    @State private var totalPlays = 0

    var body: some View {
        Form {
            Section(String(localized: "overview")) {
                LabeledContent(String(localized: "total_plays"), value: "\(totalPlays)")
                Toggle(String(localized: "mixes_from_database"), isOn: $mixUseDatabase)
            }

            Section(String(localized: "icloud_sync")) {
                Toggle(String(localized: "icloud_sync"), isOn: $iCloudSyncEnabled)
                    .onChange(of: iCloudSyncEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.handleSyncEnabledChange() }
                    }
                if iCloudSyncEnabled {
                    if let date = syncStatus.lastSyncDate {
                        LabeledContent(String(localized: "last_sync"),
                                       value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent(String(localized: "pending_uploads"), value: "\(syncStatus.pendingUploads)")
                    Button(String(localized: "sync_now")) {
                        Task { await CloudKitSyncService.shared.syncNow() }
                    }
                    .disabled(syncStatus.isSyncing)
                }
            }
        }
        .navigationTitle(String(localized: "database"))
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
