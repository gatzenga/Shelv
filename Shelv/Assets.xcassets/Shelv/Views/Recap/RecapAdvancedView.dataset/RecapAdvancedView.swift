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
            Section(tr("Testing", "Testen")) {
                Button {
                    testResult = nil
                    Task {
                        let created = await recapStore.generateTest(serverId: serverId)
                        testResult = created
                            ? tr("Playlist created.", "Playlist erstellt.")
                            : tr("No plays logged yet — skip songs first.", "Noch keine Plays — zuerst Songs skippen.")
                    }
                } label: {
                    if recapStore.isGenerating {
                        ProgressView()
                    } else {
                        Label(
                            tr("Generate test recap (last 7 days)", "Test-Recap erstellen (letzte 7 Tage)"),
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
                            Text(tr("Resetting…", "Setze zurück…")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("Reset latest weekly recap", "Letzten Wochen-Recap zurücksetzen"),
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
                            Text(tr("Resetting…", "Setze zurück…")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("Reset latest monthly recap", "Letzten Monats-Recap zurücksetzen"),
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
                            Text(tr("Resetting…", "Setze zurück…")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("Reset latest yearly recap", "Letzten Jahres-Recap zurücksetzen"),
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

            Section(tr("Destructive actions", "Löschaktionen")) {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label(
                        tr("Reset local database", "Lokale Datenbank zurücksetzen"),
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
                            Text(tr("Deleting…", "Lösche…")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("Delete iCloud data", "iCloud-Daten löschen"),
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
                            Text(tr("Deleting…", "Lösche…")).foregroundStyle(.red)
                        }
                    } else {
                        Label(
                            tr("Delete everything", "Alles löschen"),
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
        .navigationTitle(tr("Advanced", "Erweitert"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            tr("Reset local database?", "Lokale Datenbank zurücksetzen?"),
            isPresented: $showResetConfirm
        ) {
            Button(tr("Reset", "Zurücksetzen"), role: .destructive) {
                Task {
                    await PlayLogService.shared.resetLog(serverId: serverId)
                    await PlayLogService.shared.resetRegistry(serverId: serverId)
                    await CloudKitSyncService.shared.resetChangeToken()
                    await recapStore.loadEntries(serverId: serverId)
                    NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
                    testResult = nil
                }
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr(
                "Clears the local cache only. iCloud and Navidrome stay untouched. Next sync will re-fetch from iCloud.",
                "Löscht nur den lokalen Cache. iCloud und Navidrome bleiben unberührt. Beim nächsten Sync kommt alles aus iCloud zurück."
            ))
        }
        .alert(
            tr("Delete iCloud data?", "iCloud-Daten löschen?"),
            isPresented: $showIcloudResetConfirm
        ) {
            Button(tr("Delete", "Löschen"), role: .destructive) {
                Task { await performIcloudReset() }
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr(
                "All iCloud records for this server will be deleted. Local database and Navidrome playlists stay untouched.",
                "Alle iCloud-Einträge für diesen Server werden gelöscht. Lokale Datenbank und Navidrome-Playlists bleiben unberührt."
            ))
        }
        .alert(
            tr("Reset latest weekly recap?", "Letzten Wochen-Recap zurücksetzen?"),
            isPresented: $showResetLastWeekConfirm
        ) {
            Button(tr("Reset", "Zurücksetzen"), role: .destructive) {
                Task { await performResetLastWeek() }
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr(
                "Deletes the newest weekly recap (playlist, iCloud marker, local entry) and clears the auto-generation timestamp. Restart the app to trigger regeneration.",
                "Löscht den neuesten Wochen-Recap (Playlist, iCloud-Marker, DB-Eintrag) und setzt den Zeitstempel der Auto-Generation zurück. App neu starten, um die Neu-Generation auszulösen."
            ))
        }
        .alert(
            tr("Reset latest monthly recap?", "Letzten Monats-Recap zurücksetzen?"),
            isPresented: $showResetLastMonthConfirm
        ) {
            Button(tr("Reset", "Zurücksetzen"), role: .destructive) {
                Task { await performResetLastMonth() }
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr(
                "Deletes the newest monthly recap and clears its auto-generation timestamp. Restart the app to trigger regeneration.",
                "Löscht den neuesten Monats-Recap und setzt den Zeitstempel der Auto-Generation zurück. App neu starten, um die Neu-Generation auszulösen."
            ))
        }
        .alert(
            tr("Reset latest yearly recap?", "Letzten Jahres-Recap zurücksetzen?"),
            isPresented: $showResetLastYearConfirm
        ) {
            Button(tr("Reset", "Zurücksetzen"), role: .destructive) {
                Task { await performResetLastYear() }
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr(
                "Deletes the newest yearly recap and clears its auto-generation timestamp. Restart the app to trigger regeneration.",
                "Löscht den neuesten Jahres-Recap und setzt den Zeitstempel der Auto-Generation zurück. App neu starten, um die Neu-Generation auszulösen."
            ))
        }
        .alert(
            tr("Delete everything?", "Alles löschen?"),
            isPresented: $showFullResetConfirm
        ) {
            Button(tr("Delete everything", "Alles löschen"), role: .destructive) {
                Task { await performFullReset() }
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr(
                "All recap playlists on Navidrome, local play logs and iCloud records for this server will be permanently deleted. This bypasses the iCloud sync toggle.",
                "Alle Recap-Playlists auf Navidrome, lokale Plays und iCloud-Einträge für diesen Server werden unwiderruflich gelöscht. Umgeht den iCloud-Sync-Schalter."
            ))
        }
    }

    private func performResetLastWeek() async {
        isResettingLastWeek = true
        defer { isResettingLastWeek = false }
        resetLastWeekResult = nil
        let removed = await recapStore.resetLastWeek(serverId: serverId)
        resetLastWeekResult = removed
            ? tr("Removed — restart the app to regenerate.", "Entfernt — App neu starten zum Regenerieren.")
            : tr("No weekly recap to reset.", "Kein Wochen-Recap vorhanden.")
    }

    private func performResetLastMonth() async {
        isResettingLastMonth = true
        defer { isResettingLastMonth = false }
        resetLastMonthResult = nil
        let removed = await recapStore.resetLastMonth(serverId: serverId)
        resetLastMonthResult = removed
            ? tr("Removed — restart the app to regenerate.", "Entfernt — App neu starten zum Regenerieren.")
            : tr("No monthly recap to reset.", "Kein Monats-Recap vorhanden.")
    }

    private func performResetLastYear() async {
        isResettingLastYear = true
        defer { isResettingLastYear = false }
        resetLastYearResult = nil
        let removed = await recapStore.resetLastYear(serverId: serverId)
        resetLastYearResult = removed
            ? tr("Removed — restart the app to regenerate.", "Entfernt — App neu starten zum Regenerieren.")
            : tr("No yearly recap to reset.", "Kein Jahres-Recap vorhanden.")
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
