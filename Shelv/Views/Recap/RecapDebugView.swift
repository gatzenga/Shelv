import SwiftUI

struct RecapDebugView: View {
    let serverId: String
    @EnvironmentObject var recapStore: RecapStore
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var logs: [PlayLogRecord] = []
    @State private var logCount: Int = 0
    @State private var testResult: String?
    @State private var showResetConfirm = false
    @State private var showVerifySheet = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss"
        return f
    }()

    var body: some View {
        List {
            Section {
                HStack {
                    Text(tr("Total plays", "Gesamte Plays"))
                    Spacer()
                    Text("\(logCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button {
                    testResult = nil
                    Task {
                        let created = await recapStore.generateTest(serverId: serverId)
                        await refresh()
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
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = recapStore.generationError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    showVerifySheet = true
                } label: {
                    Label(
                        tr("Sync with Navidrome", "Mit Navidrome abgleichen"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .foregroundStyle(accentColor)
                }
            }

            Section(tr("Recent plays (last 50)", "Letzte Plays (50)")) {
                if logs.isEmpty {
                    Text(tr("No plays recorded yet.", "Noch keine Plays aufgezeichnet."))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.songId)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            HStack {
                                Text(Self.dateFmt.string(from: Date(timeIntervalSince1970: log.playedAt)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(log.songDuration))s")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section(tr("Registry", "Registry")) {
                if recapStore.entries.isEmpty {
                    Text(tr("No recap playlists yet.", "Noch keine Recap-Playlists."))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(recapStore.entries, id: \.playlistId) { entry in
                        let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
                        let period = RecapPeriod(
                            type: type,
                            start: Date(timeIntervalSince1970: entry.periodStart),
                            end: Date(timeIntervalSince1970: entry.periodEnd)
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(period.playlistName)
                                .font(.subheadline)
                            Text(entry.playlistId)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }

            }

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label(
                        tr("Reset database", "Datenbank zurücksetzen"),
                        systemImage: "trash"
                    )
                    .foregroundStyle(.red)
                }
            }

            PlayerBottomSpacer(activeHeight: 110, inactiveHeight: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .refreshable { await refresh() }
        .sheet(isPresented: $showVerifySheet, onDismiss: {
            Task { await refresh() }
        }) {
            RecapVerifyView(serverId: serverId)
                .environmentObject(recapStore)
        }
        .alert(
            tr("Reset database?", "Datenbank zurücksetzen?"),
            isPresented: $showResetConfirm
        ) {
            Button(tr("Reset", "Zurücksetzen"), role: .destructive) {
                Task {
                    await PlayLogService.shared.resetLog(serverId: serverId)
                    await PlayLogService.shared.resetRegistry(serverId: serverId)
                    await recapStore.loadEntries(serverId: serverId)
                    await refresh()
                    testResult = nil
                }
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr(
                "All play logs and recap entries for this server will be deleted. This cannot be undone.",
                "Alle Plays und Recap-Einträge für diesen Server werden gelöscht. Dies kann nicht rückgängig gemacht werden."
            ))
        }
        .navigationTitle(tr("Recap Log", "Recap Log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        logs = await PlayLogService.shared.recentLogs(serverId: serverId, limit: 50)
        logCount = await PlayLogService.shared.logCount(serverId: serverId)
    }
}
