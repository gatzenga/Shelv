import SwiftUI

struct RecapAdvancedView: View {
    let serverId: String
    @StateObject private var recapStore = RecapStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor

    @State private var testResult: String?
    @State private var resetLastWeekResult: String?
    @State private var resetLastMonthResult: String?
    @State private var resetLastYearResult: String?
    @State private var showResetLastWeekConfirm = false
    @State private var showResetLastMonthConfirm = false
    @State private var showResetLastYearConfirm = false
    @State private var isResettingLastWeek = false
    @State private var isResettingLastMonth = false
    @State private var isResettingLastYear = false

    var body: some View {
        Form {
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
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            String(localized: "generate_test_recap_last_7_days"),
                            systemImage: "wand.and.stars"
                        )
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
                            ProgressView().controlSize(.small)
                            Text(String(localized: "resetting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(String(localized: "reset_latest_weekly_recap"),
                              systemImage: "arrow.uturn.backward.circle")
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
                            ProgressView().controlSize(.small)
                            Text(String(localized: "resetting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(String(localized: "reset_latest_monthly_recap"),
                              systemImage: "arrow.uturn.backward.circle")
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
                            ProgressView().controlSize(.small)
                            Text(String(localized: "resetting")).foregroundStyle(.red)
                        }
                    } else {
                        Label(String(localized: "reset_latest_yearly_recap"),
                              systemImage: "arrow.uturn.backward.circle")
                            .foregroundStyle(.red)
                    }
                }
                .disabled(isResettingLastYear)

                if let result = resetLastYearResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 540, height: 520)
        .navigationTitle(String(localized: "advanced"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
        }
        .confirmationDialog(
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
        .confirmationDialog(
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
        .confirmationDialog(
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

}
