import SwiftUI
import UniformTypeIdentifiers

private struct ShareableFileWrap: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct RecapSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var recapStore: RecapStore
    @EnvironmentObject var ckStatus: CloudKitSyncStatus
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("recapWeeklyEnabled")   private var recapWeeklyEnabled   = true
    @AppStorage("recapMonthlyEnabled")  private var recapMonthlyEnabled  = true
    @AppStorage("recapYearlyEnabled")   private var recapYearlyEnabled   = true
    @AppStorage("recapWeeklyRetention") private var recapWeeklyRetention = 1
    @AppStorage("recapMonthlyRetention") private var recapMonthlyRetention = 12
    @AppStorage("recapYearlyRetention") private var recapYearlyRetention = 3
    @AppStorage("recapThreshold")       private var recapThreshold       = 30

    @State private var showImportFilePicker = false
    @State private var showSyncReport = false
    @State private var showVerifySheet = false
    @State private var isSyncingManually = false
    @State private var isPreparingExport = false
    @State private var exportItem: ShareableFileWrap?
    @State private var exportError: String?
    @State private var totalPlays: Int = 0

    @State private var weekRetentionDraft: Int = 1
    @State private var monthRetentionDraft: Int = 12
    @State private var yearRetentionDraft: Int = 3
    @State private var pendingRetention: PendingRetentionChange?

    private struct PendingRetentionChange: Identifiable {
        let id = UUID()
        let type: RecapPeriod.PeriodType
        let newValue: Int
        let excess: Int
    }

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            // MARK: Perioden
            Section(tr("Periods", "Perioden")) {
                recapPeriodRow(
                    title: tr("Weekly", "Wöchentlich"),
                    icon: "calendar",
                    enabled: $recapWeeklyEnabled,
                    retention: $weekRetentionDraft,
                    retentionRange: 1...52,
                    type: .week
                )
                recapPeriodRow(
                    title: tr("Monthly", "Monatlich"),
                    icon: "calendar.badge.clock",
                    enabled: $recapMonthlyEnabled,
                    retention: $monthRetentionDraft,
                    retentionRange: 1...24,
                    type: .month
                )
                recapPeriodRow(
                    title: tr("Yearly", "Jährlich"),
                    icon: "calendar.badge.checkmark",
                    enabled: $recapYearlyEnabled,
                    retention: $yearRetentionDraft,
                    retentionRange: 1...10,
                    type: .year
                )
                Picker(selection: $recapThreshold) {
                    ForEach([10, 20, 30, 40, 50], id: \.self) { pct in
                        Text("\(pct)%").tag(pct)
                    }
                } label: {
                    Label { Text(tr("Count from", "Zählen ab")) } icon: {
                        Image(systemName: "checkmark.seal").foregroundStyle(accentColor)
                    }
                }
            }

            // MARK: Overview
            Section(tr("Overview", "Übersicht")) {
                HStack {
                    Label { Text(tr("Total plays", "Gesamte Plays")) } icon: {
                        Image(systemName: "music.note.list").foregroundStyle(accentColor)
                    }
                    Spacer()
                    Text("\(totalPlays)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Button {
                    showVerifySheet = true
                } label: {
                    Label { Text(tr("Sync with Navidrome", "Mit Navidrome abgleichen")) } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(accentColor)
                    }
                }
            }

            // MARK: Datenbank
            Section(tr("Database", "Datenbank")) {
                Button {
                    guard !isPreparingExport else { return }
                    isPreparingExport = true
                    Task {
                        defer { isPreparingExport = false }
                        do {
                            let url = try await recapStore.exportBackupURL()
                            exportItem = ShareableFileWrap(url: url)
                        } catch {
                            exportError = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        Label { Text(tr("Export database", "Datenbank exportieren")) } icon: {
                            Image(systemName: "square.and.arrow.up").foregroundStyle(accentColor)
                        }
                        if isPreparingExport { Spacer(); ProgressView() }
                    }
                }
                .disabled(isPreparingExport)

                Button {
                    showImportFilePicker = true
                } label: {
                    Label { Text(tr("Import database", "Datenbank importieren")) } icon: {
                        Image(systemName: "square.and.arrow.down").foregroundStyle(accentColor)
                    }
                }
            }

            // MARK: iCloud Sync
            Section(tr("iCloud Sync", "iCloud-Sync")) {
                if !ckStatus.accountAvailable {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud.slash")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("No iCloud account", "Kein iCloud-Konto"))
                                .font(.subheadline)
                            Text(tr("Use Export/Import as backup instead.", "Export/Import als Datensicherung nutzen."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack {
                        Label { Text(tr("Last sync", "Letzter Sync")) } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accentColor)
                        }
                        Spacer()
                        if let date = ckStatus.lastSyncDate {
                            Text(date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(tr("Never", "Noch nie"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Label { Text(tr("Pending uploads", "Ausstehende Uploads")) } icon: {
                            Image(systemName: "icloud.and.arrow.up").foregroundStyle(accentColor)
                        }
                        Spacer()
                        Text(ckStatus.pendingUploads > 0 ? "\(ckStatus.pendingUploads)" : "—")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }

                    HStack {
                        Label { Text(tr("Pending scrobbles", "Ausstehende Scrobbles")) } icon: {
                            Image(systemName: "waveform.badge.plus").foregroundStyle(accentColor)
                        }
                        Spacer()
                        Text(ckStatus.pendingScrobbles > 0 ? "\(ckStatus.pendingScrobbles)" : "—")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
                            Label { Text(tr("Sync now", "Jetzt synchronisieren")) } icon: {
                                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accentColor)
                            }
                            if isSyncingManually { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isSyncingManually)
                }
            }

            // MARK: Logs
            if let sid = serverStore.activeServer?.stableId {
                Section(tr("Logs", "Logs")) {
                    NavigationLink(destination: RecapPlayLogView(serverId: sid)) {
                        Label { Text(tr("Recent plays", "Letzte Plays")) } icon: {
                            Image(systemName: "list.bullet.clipboard").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination:
                        RecapRegistryView(serverId: sid)
                            .environmentObject(recapStore)
                    ) {
                        Label { Text(tr("Registry", "Registry")) } icon: {
                            Image(systemName: "square.stack.3d.up").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination:
                        RecapCreationLogView()
                            .environmentObject(ckStatus)
                    ) {
                        Label { Text(tr("Recap log", "Recap-Protokoll")) } icon: {
                            Image(systemName: "sparkles.rectangle.stack").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination:
                        RecapSyncLogView()
                            .environmentObject(ckStatus)
                    ) {
                        Label { Text(tr("Sync log", "Sync-Protokoll")) } icon: {
                            Image(systemName: "doc.text").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination: RecapDBLogView()) {
                        Label { Text(tr("Database errors", "Datenbank-Fehler")) } icon: {
                            Image(systemName: "exclamationmark.octagon").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination: RecapMarkersLogView(serverId: sid)) {
                        Label { Text(tr("Auto-gen markers", "Auto-Gen-Marker")) } icon: {
                            Image(systemName: "checkmark.circle.badge.questionmark").foregroundStyle(accentColor)
                        }
                    }
                }

                // MARK: Erweitert
                Section {
                    NavigationLink(destination:
                        RecapAdvancedView(serverId: sid)
                            .environmentObject(recapStore)
                    ) {
                        Label { Text(tr("Advanced", "Erweitert")) } icon: {
                            Image(systemName: "slider.horizontal.2.square").foregroundStyle(accentColor)
                        }
                    }
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .navigationTitle(tr("Recap Settings", "Recap-Einstellungen"))
        .sheet(item: $exportItem) { file in
            ActivityView(items: [file.url])
        }
        .alert(
            tr("Export failed", "Export fehlgeschlagen"),
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } }),
            presenting: exportError
        ) { _ in
            Button(tr("OK", "OK"), role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .fileImporter(isPresented: $showImportFilePicker, allowedContentTypes: [.item]) { result in
            guard let url = try? result.get(),
                  let sid = serverStore.activeServer?.stableId else { return }
            Task { await recapStore.importDatabase(from: url, serverId: sid) }
        }
        .sheet(isPresented: $showSyncReport) {
            syncReportSheet
        }
        .sheet(isPresented: $showVerifySheet, onDismiss: {
            Task { await refreshTotalPlays() }
        }) {
            if let sid = serverStore.activeServer?.stableId {
                RecapVerifyView(serverId: sid)
                    .environmentObject(recapStore)
            }
        }
        .onChange(of: recapStore.showSyncReport) { _, show in
            if show { showSyncReport = true; recapStore.showSyncReport = false }
        }
        .task(id: serverStore.activeServerID) { await refreshTotalPlays() }
        .task {
            weekRetentionDraft  = recapWeeklyRetention
            monthRetentionDraft = recapMonthlyRetention
            yearRetentionDraft  = recapYearlyRetention
        }
        .onReceive(NotificationCenter.default.publisher(for: .recapRegistryUpdated)) { _ in
            Task { await refreshTotalPlays() }
        }
        .onChange(of: ckStatus.lastSyncDate) { _, _ in
            Task { await refreshTotalPlays() }
        }
        .alert(
            pendingRetention.map {
                tr(
                    "Delete \($0.excess) \(periodTypeName($0.type))?",
                    "\($0.excess) \(periodTypeName($0.type)) löschen?"
                )
            } ?? "",
            isPresented: Binding(
                get: { pendingRetention != nil },
                set: { if !$0 { pendingRetention = nil } }
            ),
            presenting: pendingRetention
        ) { pending in
            Button(tr("Delete", "Löschen"), role: .destructive) {
                guard let sid = serverStore.activeServer?.stableId else { return }
                let type = pending.type
                let newValue = pending.newValue
                Task {
                    await recapStore.applyRetention(
                        periodType: type, limit: newValue, serverId: sid
                    )
                    setStoredRetention(type, newValue)
                }
                pendingRetention = nil
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {
                setDraft(pending.type, storedRetention(for: pending.type))
                pendingRetention = nil
            }
        } message: { _ in
            Text(tr(
                "These playlists will be permanently deleted from Navidrome and iCloud.",
                "Diese Playlists werden unwiderruflich aus Navidrome und iCloud gelöscht."
            ))
        }
    }

    private func refreshTotalPlays() async {
        guard let sid = serverStore.activeServer?.stableId else {
            totalPlays = 0
            return
        }
        totalPlays = await PlayLogService.shared.logCount(serverId: sid)
    }

    // MARK: - Period Row

    @ViewBuilder
    private func recapPeriodRow(
        title: String, icon: String,
        enabled: Binding<Bool>,
        retention: Binding<Int>,
        retentionRange: ClosedRange<Int>,
        type: RecapPeriod.PeriodType
    ) -> some View {
        Toggle(isOn: enabled) {
            Label { Text(title) } icon: {
                Image(systemName: icon).foregroundStyle(accentColor)
            }
        }
        .tint(accentColor)

        if enabled.wrappedValue {
            Stepper(value: retention, in: retentionRange) {
                HStack {
                    Text(tr("Keep", "Behalten")).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(retention.wrappedValue)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.leading, 36)
            .onChange(of: retention.wrappedValue) { _, newValue in
                handleRetentionChange(type: type, newValue: newValue)
            }
        }
    }

    private func storedRetention(for type: RecapPeriod.PeriodType) -> Int {
        switch type {
        case .week:  return recapWeeklyRetention
        case .month: return recapMonthlyRetention
        case .year:  return recapYearlyRetention
        }
    }

    private func setStoredRetention(_ type: RecapPeriod.PeriodType, _ value: Int) {
        switch type {
        case .week:  recapWeeklyRetention = value
        case .month: recapMonthlyRetention = value
        case .year:  recapYearlyRetention = value
        }
    }

    private func setDraft(_ type: RecapPeriod.PeriodType, _ value: Int) {
        switch type {
        case .week:  weekRetentionDraft = value
        case .month: monthRetentionDraft = value
        case .year:  yearRetentionDraft = value
        }
    }

    private func handleRetentionChange(type: RecapPeriod.PeriodType, newValue: Int) {
        let current = storedRetention(for: type)
        guard newValue != current else { return }
        guard newValue < current else {
            setStoredRetention(type, newValue)
            return
        }
        guard let sid = serverStore.activeServer?.stableId else {
            setDraft(type, current)
            return
        }
        Task {
            let excess = await recapStore.excessRetentionCount(
                periodType: type, limit: newValue, serverId: sid
            )
            if excess > 0 {
                pendingRetention = PendingRetentionChange(type: type, newValue: newValue, excess: excess)
            } else {
                setStoredRetention(type, newValue)
            }
        }
    }

    private func periodTypeName(_ type: RecapPeriod.PeriodType) -> String {
        switch type {
        case .week:  return tr("weekly recaps", "Wochen-Recaps")
        case .month: return tr("monthly recaps", "Monats-Recaps")
        case .year:  return tr("yearly recaps", "Jahres-Recaps")
        }
    }

    // MARK: - Sheets

    private var syncReportSheet: some View {
        NavigationStack {
            List(recapStore.syncReports) { report in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: report.isError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(report.isError ? .red : accentColor)
                    Text(report.message).font(.subheadline)
                }
            }
            .navigationTitle(tr("Recap Sync", "Recap Sync"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done", "Fertig")) { showSyncReport = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(24)
    }

}
