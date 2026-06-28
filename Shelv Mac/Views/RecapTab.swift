import SwiftUI

struct RecapTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var recapStore = RecapStore.shared
    @Environment(\.themeColor) private var themeColor

    @AppStorage("recapEnabled")          private var recapEnabled          = false
    @AppStorage("recapWeeklyEnabled")    private var recapWeeklyEnabled    = true
    @AppStorage("recapMonthlyEnabled")   private var recapMonthlyEnabled   = true
    @AppStorage("recapYearlyEnabled")    private var recapYearlyEnabled    = true
    @AppStorage("recapWeeklyRetention")  private var recapWeeklyRetention  = 1
    @AppStorage("recapMonthlyRetention") private var recapMonthlyRetention = 12
    @AppStorage("recapYearlyRetention")  private var recapYearlyRetention  = 3

    @State private var showRegistry = false
    @State private var showRecapLog = false
    @State private var showMarkersLog = false
    @State private var showAdvanced = false
    @State private var showVerify = false

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

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "enable_recap"), isOn: $recapEnabled)
            } footer: {
                if !recapEnabled {
                    Text(String(localized: "track_your_listening_history_and_generate_automati"))
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            if recapEnabled {
                Section(String(localized: "periods")) {
                    periodRow(title: String(localized: "weekly"),
                              enabled: $recapWeeklyEnabled,
                              retention: $weekRetentionDraft, range: 1...52,
                              type: .week)
                    periodRow(title: String(localized: "monthly"),
                              enabled: $recapMonthlyEnabled,
                              retention: $monthRetentionDraft, range: 1...24,
                              type: .month)
                    periodRow(title: String(localized: "yearly"),
                              enabled: $recapYearlyEnabled,
                              retention: $yearRetentionDraft, range: 1...10,
                              type: .year)
                }

                Section(String(localized: "logs")) {
                    Button {
                        showRegistry = true
                    } label: {
                        Label(String(localized: "registry"), systemImage: "square.stack.3d.up")
                    }
                    Button {
                        showRecapLog = true
                    } label: {
                        Label(String(localized: "recap_log"), systemImage: "sparkles.rectangle.stack")
                    }
                    Button {
                        showMarkersLog = true
                    } label: {
                        Label(String(localized: "autogen_markers"), systemImage: "checkmark.circle.badge.questionmark")
                    }
                }

                Section(String(localized: "actions")) {
                    Button {
                        showVerify = true
                    } label: {
                        Label(String(localized: "sync_with_navidrome"),
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        showAdvanced = true
                    } label: {
                        Label(String(localized: "advanced"), systemImage: "slider.horizontal.2.square")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            weekRetentionDraft  = recapWeeklyRetention
            monthRetentionDraft = recapMonthlyRetention
            yearRetentionDraft  = recapYearlyRetention
        }
        .alert(
            pendingRetention.map {
                String(format: String(localized: "delete_count_period_format"), $0.excess, periodTypeName($0.type))
            } ?? "",
            isPresented: Binding(
                get: { pendingRetention != nil },
                set: { if !$0 { pendingRetention = nil } }
            ),
            presenting: pendingRetention
        ) { pending in
            Button(String(localized: "delete"), role: .destructive) {
                guard let sid = appState.serverStore.activeServer?.stableId else { return }
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
            Button(String(localized: "cancel"), role: .cancel) {
                setDraft(pending.type, storedRetention(for: pending.type))
                pendingRetention = nil
            }
        } message: { _ in
            Text(String(localized: "these_playlists_will_be_permanently_deleted_from_n"))
        }
        .sheet(isPresented: $showRegistry) {
            if let sid = appState.serverStore.activeServer?.stableId {
                RecapRegistryView(serverId: sid)
            }
        }
        .sheet(isPresented: $showRecapLog) {
            RecapCreationLogView()
        }
        .sheet(isPresented: $showMarkersLog) {
            if let sid = appState.serverStore.activeServer?.stableId {
                RecapMarkersLogView(serverId: sid)
            }
        }
        .sheet(isPresented: $showAdvanced) {
            if let sid = appState.serverStore.activeServer?.stableId {
                RecapAdvancedView(serverId: sid)
            }
        }
        .sheet(isPresented: $showVerify) {
            if let sid = appState.serverStore.activeServer?.stableId {
                RecapVerifyView(serverId: sid)
            }
        }
    }

    @ViewBuilder
    private func periodRow(title: String, enabled: Binding<Bool>,
                           retention: Binding<Int>, range: ClosedRange<Int>,
                           type: RecapPeriod.PeriodType) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(title, isOn: enabled)
            if enabled.wrappedValue {
                Stepper(value: retention, in: range) {
                    HStack {
                        Text(String(localized: "keep")).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(retention.wrappedValue)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .onChange(of: retention.wrappedValue) { _, newValue in
                    handleRetentionChange(type: type, newValue: newValue)
                }
            }
        }
        .padding(.vertical, 4)
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
        Task { await CloudKitSyncService.shared.recordRetentionChange() }
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
        guard let sid = appState.serverStore.activeServer?.stableId else {
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
        case .week:  return String(localized: "weekly_recaps")
        case .month: return String(localized: "monthly_recaps")
        case .year:  return String(localized: "yearly_recaps")
        }
    }
}
