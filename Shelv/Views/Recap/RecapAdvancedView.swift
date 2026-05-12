import SwiftUI

struct RecapAdvancedView: View {
    let serverId: String
    @EnvironmentObject var recapStore: RecapStore
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var testResult: String?
    @State private var resetLastWeekResult: String?
    @State private var resetLastMonthResult: String?
    @State private var resetLastYearResult: String?
    @State private var showResetConfirm = false
    @State private var showIcloudResetConfirm = false
    @State private var showFullResetConfirm = false
    @State private var showResetLastWeekConfirm = false
    @State private var showResetLastMonthConfirm = false
    @State private var showResetLastYearConfirm = false
    @State private var isIcloudResetting = false
    @State private var isFullResetting = false
    @State private var isResettingLastWeek = false
    @State private var isResettingLastMonth = false
    @State private var isResettingLastYear = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section(tr("recap.recap.advanced.testing")) {
                Button {
                    testResult = nil
                    Task {
                        let created = await recapStore.generateTest(serverId: serverId)
                        testResult = created
                            ? tr("recap.recap.advanced.playlist_created")
                            : tr("recap.recap.advanced.no_plays_logged_yet_skip_songs")
                    }
                } label: {
                    if recapStore.isGenerating {
                        ProgressView()
                    } else {
                        Label(
                            tr("recap.recap.advanced.generate_test_recap_last_7_days"),
                            systemImage: "wand.and.stars"
                        )
                        .foregroundStyle(accentColor)
                    }
                }
                .disabled(recapStore.isGenerating)

                if let result = testResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
                if let err = recapStore.generationError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                Button(role: .destructive) {
                    showResetLastWeekConfirm = true
                } label: {
                    if isResettingLastWeek {
                        HStack {
                            ProgressView()
                            Text(tr("recap.recap.advanced.resetting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("recap.recap.advanced.reset_latest_weekly_recap"),
                            systemImage: "arrow.uturn.backward.circle"
                        )
                        .foregroundStyle(.red)
                    }
                }
                .disabled(isResettingLastWeek)

                if let result = resetLastWeekResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    showResetLastMonthConfirm = true
                } label: {
                    if isResettingLastMonth {
                        HStack {
                            ProgressView()
                            Text(tr("recap.recap.advanced.resetting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("recap.recap.advanced.reset_latest_monthly_recap"),
                            systemImage: "arrow.uturn.backward.circle"
                        )
                        .foregroundStyle(.red)
                    }
                }
                .disabled(isResettingLastMonth)

                if let result = resetLastMonthResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    showResetLastYearConfirm = true
                } label: {
                    if isResettingLastYear {
                        HStack {
                            ProgressView()
                            Text(tr("recap.recap.advanced.resetting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("recap.recap.advanced.reset_latest_yearly_recap"),
                            systemImage: "arrow.uturn.backward.circle"
                        )
                        .foregroundStyle(.red)
                    }
                }
                .disabled(isResettingLastYear)

                if let result = resetLastYearResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(tr("recap.recap.advanced.destructive_actions")) {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label(
                        tr("recap.recap.advanced.reset_local_database"),
                        systemImage: "arrow.counterclockwise"
                    )
                    .foregroundStyle(.red)
                }

                Button(role: .destructive) {
                    showIcloudResetConfirm = true
                } label: {
                    if isIcloudResetting {
                        HStack {
                            ProgressView()
                            Text(tr("recap.recap.advanced.deleting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("recap.recap.advanced.delete_icloud_data"),
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
                            ProgressView()
                            Text(tr("recap.recap.advanced.deleting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("recap.recap.advanced.delete_everything"),
                            systemImage: "trash.slash"
                        )
                        .foregroundStyle(.red)
                    }
                }
                .disabled(isFullResetting)
            }

            PlayerBottomSpacer(activeHeight: 110, inactiveHeight: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .navigationTitle(tr("recap.recap.advanced.advanced"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            tr("recap.recap.advanced.reset_local_database.7ca9ccd0"),
            isPresented: $showResetConfirm
        ) {
            Button(tr("recap.recap.advanced.reset"), role: .destructive) {
                Task {
                    await PlayLogService.shared.resetLog(serverId: serverId)
                    await PlayLogService.shared.resetRegistry(serverId: serverId)
                    await CloudKitSyncService.shared.resetChangeToken()
                    await recapStore.loadEntries(serverId: serverId)
                    NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
                    testResult = nil
                }
            }
            Button(tr("downloads.cancel"), role: .cancel) {}
        } message: {
            Text(tr("recap.recap.advanced.clears_local_cache_only_icloud_navidrome"))
        }
        .alert(
            tr("recap.recap.advanced.delete_icloud_data.17547076"),
            isPresented: $showIcloudResetConfirm
        ) {
            Button(tr("downloads.delete"), role: .destructive) {
                Task { await performIcloudReset() }
            }
            Button(tr("downloads.cancel"), role: .cancel) {}
        } message: {
            Text(tr("recap.recap.advanced.icloud_records_server_deleted_local_database"))
        }
        .alert(
            tr("recap.recap.advanced.reset_latest_weekly_recap.2c4b086f"),
            isPresented: $showResetLastWeekConfirm
        ) {
            Button(tr("recap.recap.advanced.reset"), role: .destructive) {
                Task { await performResetLastWeek() }
            }
            Button(tr("downloads.cancel"), role: .cancel) {}
        } message: {
            Text(tr("recap.recap.advanced.deletes_newest_weekly_recap_playlist_icloud"))
        }
        .alert(
            tr("recap.recap.advanced.reset_latest_monthly_recap.afbe0654"),
            isPresented: $showResetLastMonthConfirm
        ) {
            Button(tr("recap.recap.advanced.reset"), role: .destructive) {
                Task { await performResetLastMonth() }
            }
            Button(tr("downloads.cancel"), role: .cancel) {}
        } message: {
            Text(tr("recap.recap.advanced.deletes_newest_monthly_recap_clears_its"))
        }
        .alert(
            tr("recap.recap.advanced.reset_latest_yearly_recap.a85dbb0b"),
            isPresented: $showResetLastYearConfirm
        ) {
            Button(tr("recap.recap.advanced.reset"), role: .destructive) {
                Task { await performResetLastYear() }
            }
            Button(tr("downloads.cancel"), role: .cancel) {}
        } message: {
            Text(tr("recap.recap.advanced.deletes_newest_yearly_recap_clears_its"))
        }
        .alert(
            tr("recap.recap.advanced.delete_everything.89188578"),
            isPresented: $showFullResetConfirm
        ) {
            Button(tr("recap.recap.advanced.delete_everything"), role: .destructive) {
                Task { await performFullReset() }
            }
            Button(tr("downloads.cancel"), role: .cancel) {}
        } message: {
            Text(tr("recap.recap.advanced.recap_playlists_navidrome_local_play_logs"))
        }
    }

    private func performResetLastWeek() async {
        isResettingLastWeek = true
        defer { isResettingLastWeek = false }
        resetLastWeekResult = nil
        let removed = await recapStore.resetLastWeek(serverId: serverId)
        resetLastWeekResult = removed
            ? tr("recap.recap.advanced.removed_restart_app_regenerate")
            : tr("recap.recap.advanced.no_weekly_recap_reset")
    }

    private func performResetLastMonth() async {
        isResettingLastMonth = true
        defer { isResettingLastMonth = false }
        resetLastMonthResult = nil
        let removed = await recapStore.resetLastMonth(serverId: serverId)
        resetLastMonthResult = removed
            ? tr("recap.recap.advanced.removed_restart_app_regenerate")
            : tr("recap.recap.advanced.no_monthly_recap_reset")
    }

    private func performResetLastYear() async {
        isResettingLastYear = true
        defer { isResettingLastYear = false }
        resetLastYearResult = nil
        let removed = await recapStore.resetLastYear(serverId: serverId)
        resetLastYearResult = removed
            ? tr("recap.recap.advanced.removed_restart_app_regenerate")
            : tr("recap.recap.advanced.no_yearly_recap_reset")
    }

    private func performIcloudReset() async {
        isIcloudResetting = true
        defer { isIcloudResetting = false }

        await CloudKitSyncService.shared.deleteZone(force: true)
        await PlayLogService.shared.markServerUnsyncedForReUpload(serverId: serverId)
        await CloudKitSyncService.shared.updatePendingCounts()
    }

    private func performFullReset() async {
        isFullResetting = true
        defer { isFullResetting = false }

        let registry = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        for entry in registry {
            try? await SubsonicAPIService.shared.deletePlaylist(id: entry.playlistId)
        }

        await CloudKitSyncService.shared.deleteZone(force: true)

        await PlayLogService.shared.resetLog(serverId: serverId)
        await PlayLogService.shared.resetRegistry(serverId: serverId)
        await PlayLogService.shared.removeScrobbles(serverId: serverId)
        await CloudKitSyncService.shared.resetChangeToken()
        await CloudKitSyncService.shared.updatePendingCounts()

        await recapStore.loadEntries(serverId: serverId)
        testResult = nil
    }
}
