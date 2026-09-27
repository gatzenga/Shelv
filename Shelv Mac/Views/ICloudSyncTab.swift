import SwiftUI

struct ICloudSyncTab: View {
    @StateObject private var ckStatus = CloudKitSyncService.shared.status
    @Environment(\.themeColor) private var themeColor

    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("iCloudSyncLyricsServerEnabled") private var lyricsServerSyncEnabled = true
    @AppStorage("iCloudSyncRadioStationsEnabled") private var radioStationsSyncEnabled = true
    @AppStorage("iCloudSyncUICustomizationsEnabled") private var uiCustomizationsSyncEnabled = true
    @AppStorage("iCloudSyncExternalServicesEnabled") private var externalServicesSyncEnabled = true

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
                            Text(String(localized: "no_icloud_account"))
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
                    .disabled(isIcloudResetting)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showSyncLog) {
            SyncLogView()
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
        return String(localized: "sync_status_idle")
    }

    @MainActor
    private func performIcloudReset() async {
        isIcloudResetting = true
        defer { isIcloudResetting = false }
        await CloudKitSyncService.shared.deleteZone(force: true)
    }
}
