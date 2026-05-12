import SwiftUI

private struct PeriodStatus {
    let period: RecapPeriod
    let processed: Bool
    let entryExists: Bool
    let plays: Int
}

struct RecapMarkersLogView: View {
    let serverId: String
    @AppStorage("themeColor") private var themeColorName = "violet"
    @State private var weekly: [PeriodStatus] = []
    @State private var monthly: PeriodStatus?
    @State private var yearly: PeriodStatus?
    @State private var isLoading = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private let rangeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d. MMM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let yearFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()

    private func rangeString(_ p: RecapPeriod) -> String {
        switch p.type {
        case .week:
            return "\(rangeFmt.string(from: p.start)) – \(rangeFmt.string(from: p.end))"
        case .month:
            let f = DateFormatter()
            f.dateFormat = "MMMM yyyy"
            return f.string(from: p.start)
        case .year:
            return yearFmt.string(from: p.start)
        }
    }

    var body: some View {
        List {
            Section {
                if weekly.isEmpty {
                    Text(String(localized: "loading"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(weekly.indices, id: \.self) { idx in
                        row(status: weekly[idx])
                    }
                }
            } header: {
                Text(String(localized: "weekly_last_4_weeks"))
            } footer: {
                Text(String(localized: "a_week_is_marked_processed_when_generate_succeeds_"))
            }

            Section(String(localized: "monthly_last_month")) {
                if let m = monthly {
                    row(status: m)
                } else {
                    Text(String(localized: "string")).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "yearly_last_year")) {
                if let y = yearly {
                    row(status: y)
                } else {
                    Text(String(localized: "string")).font(.caption).foregroundStyle(.secondary)
                }
            }

            PlayerBottomSpacer(activeHeight: 110, inactiveHeight: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .navigationTitle(String(localized: "autogen_markers"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .tint(accentColor)
                .disabled(isLoading)
            }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private func row(status: PeriodStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rangeString(status.period))
                    .font(.body.weight(.medium))
                Spacer()
                Text(status.period.periodKey)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(String(localized: "marker")).foregroundStyle(.secondary)
                Text(status.processed ? String(localized: "set") : String(localized: "not_set"))
                    .foregroundStyle(status.processed ? .green : .secondary)
                Text("·").foregroundStyle(.secondary)
                Text(String(localized: "playlist")).foregroundStyle(.secondary)
                Text(status.entryExists ? String(localized: "exists") : String(localized: "missing"))
                    .foregroundStyle(status.entryExists ? accentColor : .secondary)
                Text("·").foregroundStyle(.secondary)
                Text(String(localized: "plays")).foregroundStyle(.secondary)
                Text("\(status.plays)")
                    .foregroundStyle(status.plays > 0 ? .primary : .secondary)
            }
            .font(.caption)

            if !status.processed && status.plays == 0 {
                Text(String(localized: "will_retry_on_next_app_start_no_plays_yet"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !status.processed && status.plays > 0 && !status.entryExists {
                Text(String(localized: "pending_generation_on_next_app_start"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if status.processed && !status.entryExists {
                Text(String(localized: "processed_playlist_deleted_will_not_regenerate"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Loading

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2

        var weeks: [RecapPeriod] = []
        if let mostRecent = RecapPeriod.lastWeek() {
            weeks.append(mostRecent)
            var current = mostRecent
            for _ in 0..<3 {
                guard
                    let prevStart = cal.date(byAdding: .weekOfYear, value: -1, to: current.start),
                    let prevEnd   = cal.date(byAdding: .second, value: -1, to: current.start)
                else { break }
                current = RecapPeriod(type: .week, start: prevStart, end: prevEnd)
                weeks.append(current)
            }
        }

        let processedSet = RecapProcessedWeeks.load()
        var weeklyStatuses: [PeriodStatus] = []
        for w in weeks {
            let plays = await PlayLogService.shared.playCount(serverId: serverId, from: w.start, to: w.end)
            let entry = await PlayLogService.shared.registryEntry(
                serverId: serverId,
                periodType: RecapPeriod.PeriodType.week.rawValue,
                periodStart: w.start.timeIntervalSince1970,
                isTest: false
            )
            weeklyStatuses.append(PeriodStatus(
                period: w,
                processed: processedSet.contains(w.start.timeIntervalSince1970),
                entryExists: entry != nil,
                plays: plays
            ))
        }
        weekly = weeklyStatuses

        if let m = RecapPeriod.lastMonth() {
            let plays = await PlayLogService.shared.playCount(serverId: serverId, from: m.start, to: m.end)
            let entry = await PlayLogService.shared.registryEntry(
                serverId: serverId,
                periodType: RecapPeriod.PeriodType.month.rawValue,
                periodStart: m.start.timeIntervalSince1970,
                isTest: false
            )
            let lastGen = UserDefaults.standard.double(forKey: "recap_last_gen_month")
            monthly = PeriodStatus(
                period: m,
                processed: lastGen >= m.start.timeIntervalSince1970 && lastGen > 0,
                entryExists: entry != nil,
                plays: plays
            )
        }

        if let y = RecapPeriod.lastYear() {
            let plays = await PlayLogService.shared.playCount(serverId: serverId, from: y.start, to: y.end)
            let entry = await PlayLogService.shared.registryEntry(
                serverId: serverId,
                periodType: RecapPeriod.PeriodType.year.rawValue,
                periodStart: y.start.timeIntervalSince1970,
                isTest: false
            )
            let lastGen = UserDefaults.standard.double(forKey: "recap_last_gen_year")
            yearly = PeriodStatus(
                period: y,
                processed: lastGen >= y.start.timeIntervalSince1970 && lastGen > 0,
                entryExists: entry != nil,
                plays: plays
            )
        }
    }
}
