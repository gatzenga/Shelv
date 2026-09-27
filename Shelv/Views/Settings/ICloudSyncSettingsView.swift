import SwiftUI

struct ICloudSyncSettingsView: View {
    @EnvironmentObject var ckStatus: CloudKitSyncStatus
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("iCloudSyncLyricsServerEnabled") private var lyricsServerSyncEnabled = true
    @AppStorage("iCloudSyncRadioStationsEnabled") private var radioStationsSyncEnabled = true
    @AppStorage("iCloudSyncUICustomizationsEnabled") private var uiCustomizationsSyncEnabled = true
    @AppStorage("iCloudSyncExternalServicesEnabled") private var externalServicesSyncEnabled = true

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
                        Text(String(localized: "no_icloud_account"))
                            .font(.subheadline)
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

                    Toggle(isOn: $externalServicesSyncEnabled) {
                        Label { Text(String(localized: "external_services")) } icon: {
                            Image(systemName: "link").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .onChange(of: externalServicesSyncEnabled) { _, _ in
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
                    .disabled(isIcloudResetting)
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
        return String(localized: "sync_status_idle")
    }

    @MainActor
    private func performIcloudReset() async {
        isIcloudResetting = true
        defer { isIcloudResetting = false }
        await CloudKitSyncService.shared.deleteZone(force: true)
    }
}
