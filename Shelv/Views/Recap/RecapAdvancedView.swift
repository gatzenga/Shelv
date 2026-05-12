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
            Section(String(localized: "testing")) {
                Button {
                    testResult = nil
                    Task {
                        let created = await recapStore.generateTest(serverId: serverId)
                        testResult = created
                            ? String(localized: "playlist_created")
                            : String(localized: "no_plays_logged_yet_skip_songs_first")
                    }
                } label: {
                    if recapStore.isGenerating {
                        ProgressView()
                    } else {
                        Label(
                            String(localized: "generate_test_recap_last_7_days"),
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
                            Text(String(localized: "resetting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            String(localized: "reset_latest_weekly_recap"),
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
                            Text(String(localized: "resetting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            String(localized: "reset_latest_monthly_recap"),
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
                            Text(String(localized: "resetting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            String(localized: "reset_latest_yearly_recap"),
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

            Section(String(localized: "destructive_actions")) {
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
                            ProgressView()
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
                            ProgressView()
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

            PlayerBottomSpacer(activeHeight: 110, inactiveHeight: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .navigationTitle(String(localized: "advanced"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            String(localized: "reset_local_database_2"),
            isPresented: $showResetConfirm
        ) {
            Button(String(localized: "reset"), role: .destructive) {
                Task {
                    await PlayLogService.shared.resetLog(serverId: serverId)
                    await PlayLogService.shared.resetRegistry(serverId: serverId)
                    await CloudKitSyncService.shared.resetChangeToken()
                    await recapStore.loadEntries(serverId: serverId)
                    NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
                    testResult = nil
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
            String(localized: "reset_latest_weekly_recap_2"),
            isPresented: $showResetLastWeekConfirm
        ) {
            Button(String(localized: "reset"), role: .destructive) {
                Task { await performResetLastWeek() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "deletes_the_newest_weekly_recap_playlist_icloud_ma"))
        }
        .alert(
            String(localized: "reset_latest_monthly_recap_2"),
            isPresented: $showResetLastMonthConfirm
        ) {
            Button(String(localized: "reset"), role: .destructive) {
                Task { await performResetLastMonth() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "deletes_the_newest_monthly_recap_and_clears_its_au"))
        }
        .alert(
            String(localized: "reset_latest_yearly_recap_2"),
            isPresented: $showResetLastYearConfirm
        ) {
            Button(String(localized: "reset"), role: .destructive) {
                Task { await performResetLastYear() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "deletes_the_newest_yearly_recap_and_clears_its_aut"))
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
    }

    private func performResetLastWeek() async {
        isResettingLastWeek = true
        defer { isResettingLastWeek = false }
        resetLastWeekResult = nil
        let removed = await recapStore.resetLastWeek(serverId: serverId)
        resetLastWeekResult = removed
            ? String(localized: "removed_restart_the_app_to_regenerate")
            : String(localized: "no_weekly_recap_to_reset")
    }

    private func performResetLastMonth() async {
        isResettingLastMonth = true
        defer { isResettingLastMonth = false }
        resetLastMonthResult = nil
        let removed = await recapStore.resetLastMonth(serverId: serverId)
        resetLastMonthResult = removed
            ? String(localized: "removed_restart_the_app_to_regenerate")
            : String(localized: "no_monthly_recap_to_reset")
    }

    private func performResetLastYear() async {
        isResettingLastYear = true
        defer { isResettingLastYear = false }
        resetLastYearResult = nil
        let removed = await recapStore.resetLastYear(serverId: serverId)
        resetLastYearResult = removed
            ? String(localized: "removed_restart_the_app_to_regenerate")
            : String(localized: "no_yearly_recap_to_reset")
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
