import SwiftUI

struct ICloudSyncSettingsView: View {
    @ObservedObject private var syncStatus = CloudKitSyncService.shared.status

    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("iCloudSyncLyricsServerEnabled") private var lyricsServerSyncEnabled = true
    @AppStorage("iCloudSyncRadioStationsEnabled") private var radioStationsSyncEnabled = true
    @AppStorage("iCloudSyncUICustomizationsEnabled") private var uiCustomizationsSyncEnabled = true
    @AppStorage("iCloudSyncExternalServicesEnabled") private var externalServicesSyncEnabled = true
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
                    Toggle(String(localized: "external_services"), isOn: $externalServicesSyncEnabled)
                        .onChange(of: externalServicesSyncEnabled) { _, _ in
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
                    .disabled(isIcloudResetting)
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
        return String(localized: "sync_status_idle")
    }

    @MainActor
    private func performIcloudReset() async {
        isIcloudResetting = true
        defer { isIcloudResetting = false }
        await CloudKitSyncService.shared.deleteZone(force: true)
    }
}

/// Live sync log that updates as the CloudKit status receives new lines.
private struct SyncLogView: View {
    @ObservedObject private var status = CloudKitSyncService.shared.status

    var body: some View {
        LogListView(title: String(localized: "sync_log"), entries: status.logEntries)
    }
}
