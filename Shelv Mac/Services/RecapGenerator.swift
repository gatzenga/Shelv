import Foundation

struct RecapPeriod {
    enum PeriodType: String {
        case week, month, year

        nonisolated var songLimit: Int {
            switch self {
            case .week:         return 25
            case .month, .year: return 50
            }
        }

        static let weekGraceHours  = 6
        static let monthGraceHours = 6
        static let yearGraceHours  = 6

        var gracePeriodHours: Int {
            switch self {
            case .week:  return Self.weekGraceHours
            case .month: return Self.monthGraceHours
            case .year:  return Self.yearGraceHours
            }
        }

        nonisolated var retentionKey: String {
            switch self {
            case .week:  return "recapWeeklyRetention"
            case .month: return "recapMonthlyRetention"
            case .year:  return "recapYearlyRetention"
            }
        }

        nonisolated var defaultRetention: Int {
            switch self {
            case .week:  return 1
            case .month: return 12
            case .year:  return 3
            }
        }
    }

    let type: PeriodType
    let start: Date
    let end: Date

    nonisolated var playlistName: String {
        switch type {
        case .week:
            var cal = Calendar(identifier: .gregorian)
            cal.locale = Locale(identifier: "en_US_POSIX")
            let startYear  = cal.component(.year, from: start)
            let endYear    = cal.component(.year, from: end)
            let startMonth = cal.component(.month, from: start)
            let endMonth   = cal.component(.month, from: end)

            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "d"

            let monthFmt = DateFormatter()
            monthFmt.dateFormat = "MMM"
            monthFmt.locale = Locale(identifier: "en_US_POSIX")

            let yearFmt = DateFormatter()
            yearFmt.dateFormat = "yyyy"

            let sd = dayFmt.string(from: start)
            let ed = dayFmt.string(from: end)
            let sm = monthFmt.string(from: start)
            let em = monthFmt.string(from: end)
            let sy = yearFmt.string(from: start)
            let ey = yearFmt.string(from: end)

            if startYear != endYear {
                return "\(sd). \(sm) \(sy) – \(ed). \(em) \(ey)"
            } else if startMonth == endMonth {
                return "\(sd).–\(ed). \(em) \(ey)"
            } else {
                return "\(sd). \(sm) – \(ed). \(em) \(ey)"
            }
        case .month:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMMM yyyy"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            return fmt.string(from: start)
        case .year:
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy"
            return fmt.string(from: start)
        }
    }
}

extension RecapPeriod {
    static func lastWeek(relativeTo now: Date = Date()) -> RecapPeriod? {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        guard
            let startOfThisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start,
            let start = cal.date(byAdding: .weekOfYear, value: -1, to: startOfThisWeek),
            let end   = cal.date(byAdding: .second, value: -1, to: startOfThisWeek)
        else { return nil }
        return RecapPeriod(type: .week, start: start, end: end)
    }

    static func lastMonth(relativeTo now: Date = Date()) -> RecapPeriod? {
        let cal = Calendar.current
        guard
            let startOfThisMonth = cal.dateInterval(of: .month, for: now)?.start,
            let start = cal.date(byAdding: .month, value: -1, to: startOfThisMonth),
            let end   = cal.date(byAdding: .second, value: -1, to: startOfThisMonth)
        else { return nil }
        return RecapPeriod(type: .month, start: start, end: end)
    }

    static func lastYear(relativeTo now: Date = Date()) -> RecapPeriod? {
        let cal = Calendar.current
        guard
            let startOfThisYear = cal.dateInterval(of: .year, for: now)?.start,
            let start = cal.date(byAdding: .year, value: -1, to: startOfThisYear),
            let end   = cal.date(byAdding: .second, value: -1, to: startOfThisYear)
        else { return nil }
        return RecapPeriod(type: .year, start: start, end: end)
    }
}

extension RecapPeriod {
    nonisolated var periodKey: String {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        switch type {
        case .week:
            let week = cal.component(.weekOfYear, from: start)
            let year = cal.component(.yearForWeekOfYear, from: start)
            return String(format: "%04d-W%02d", year, week)
        case .month:
            let comps = cal.dateComponents([.year, .month], from: start)
            return String(format: "%04d-%02d", comps.year!, comps.month!)
        case .year:
            let year = cal.component(.year, from: start)
            return String(format: "%04d", year)
        }
    }
}

enum GenerateOutcome {
    case created
    case adopted
    case skippedExistingEntry
    case skippedNoPlays
}

actor RecapGenerator {
    static let shared = RecapGenerator()
    private init() {}

    @discardableResult
    func generate(period: RecapPeriod, serverId: String, trigger: String = "auto", isTest: Bool = false) async throws -> GenerateOutcome {
        let basePart = "\(serverId.lowercased()).\(period.periodKey)"
        let recordName = isTest ? "test.\(basePart)" : basePart

        CloudKitSyncService.recapLog("[RecapGen] ── Trigger: \(trigger)\(isTest ? " [TEST]" : "") ──")
        CloudKitSyncService.recapLog("[RecapGen] Period: \(period.type.rawValue) \(period.playlistName)")
        CloudKitSyncService.recapLog("[RecapGen] periodKey: \(period.periodKey)")
        CloudKitSyncService.recapLog("[RecapGen] recordName: \(recordName)")

        CloudKitSyncService.recapLog("[RecapGen] Step 1: flushAndWait")
        do {
            try await CloudKitSyncService.shared.flushAndWait()
            CloudKitSyncService.recapLog("[RecapGen] Step 1: flushAndWait — done")
        } catch {
            CloudKitSyncService.recapLog("[RecapGen] Step 1: flushAndWait — failed: \(error.localizedDescription)")
            throw error
        }

        CloudKitSyncService.recapLog("[RecapGen] Step 2: local registry check (ckRecordName)")
        if await PlayLogService.shared.registryEntry(byCKRecordName: recordName) != nil {
            CloudKitSyncService.recapLog("[RecapGen] Step 2: FOUND — existing entry matched by ckRecordName")
            CloudKitSyncService.recapLog("[RecapGen] Result: SKIPPED — playlist already exists for this period")
            return .skippedExistingEntry
        }
        CloudKitSyncService.recapLog("[RecapGen] Step 2: not found")

        CloudKitSyncService.recapLog("[RecapGen] Step 3: local registry check (periodStart, isTest=\(isTest))")
        if await PlayLogService.shared.registryEntry(
            serverId: serverId,
            periodType: period.type.rawValue,
            periodStart: period.start.timeIntervalSince1970,
            isTest: isTest
        ) != nil {
            CloudKitSyncService.recapLog("[RecapGen] Step 3: FOUND — existing entry matched by periodStart")
            CloudKitSyncService.recapLog("[RecapGen] Result: SKIPPED — playlist already exists for this period")
            return .skippedExistingEntry
        }
        CloudKitSyncService.recapLog("[RecapGen] Step 3: not found")

        CloudKitSyncService.recapLog("[RecapGen] Step 4: iCloud marker fetch (isTest=\(isTest))")
        if let existing = await CloudKitSyncService.shared.fetchRecapMarker(
            serverId: serverId, periodKey: period.periodKey, isTest: isTest
        ) {
            CloudKitSyncService.recapLog("[RecapGen] Step 4: FOUND — adopting iCloud marker, playlistId=\(existing.playlistId)")
            await PlayLogService.shared.registerPlaylist(existing)
            CloudKitSyncService.recapLog("[RecapGen] Result: ADOPTED — registered remote playlist (\(existing.playlistId))")
            return .adopted
        }
        CloudKitSyncService.recapLog("[RecapGen] Step 4: not found")

        CloudKitSyncService.recapLog("[RecapGen] Step 5: top songs query (limit=\(period.type.songLimit))")
        let topSongs = await PlayLogService.shared.topSongs(
            serverId: serverId,
            from: period.start,
            to: period.end,
            limit: period.type.songLimit
        )
        CloudKitSyncService.recapLog("[RecapGen] Step 5: \(topSongs.count) plays found")
        guard !topSongs.isEmpty else {
            CloudKitSyncService.recapLog("[RecapGen] Result: ABORTED — no plays in period")
            return .skippedNoPlays
        }

        CloudKitSyncService.recapLog("[RecapGen] Step 6: Navidrome createPlaylist")
        let songIds = topSongs.map { $0.songId }
        let playlist: Playlist
        do {
            playlist = try await SubsonicAPIService.shared.createPlaylist(
                name: period.playlistName,
                songIds: songIds,
                comment: "Shelv Recap"
            )
            CloudKitSyncService.recapLog("[RecapGen] Step 6: created playlistId=\(playlist.id)")
        } catch {
            CloudKitSyncService.recapLog("[RecapGen] Step 6: FAILED — \(error.localizedDescription)")
            CloudKitSyncService.recapLog("[RecapGen] Result: FAILED — Navidrome createPlaylist failed")
            throw error
        }

        var entry = RecapRegistryRecord(
            playlistId: playlist.id,
            serverId: serverId,
            periodType: period.type.rawValue,
            periodStart: period.start.timeIntervalSince1970,
            periodEnd: period.end.timeIntervalSince1970,
            ckRecordName: nil,
            isTest: isTest
        )

        CloudKitSyncService.recapLog("[RecapGen] Step 7: saveRecapMarker")
        var resultTag = "CREATED"
        var outcome: GenerateOutcome = .created
        if let markerResult = try? await CloudKitSyncService.shared.saveRecapMarker(entry, periodKey: period.periodKey) {
            switch markerResult {
            case .created:
                CloudKitSyncService.recapLog("[RecapGen] Step 7: created new iCloud marker")
                entry.ckRecordName = recordName
            case .conflict(let existingPlaylistId):
                CloudKitSyncService.recapLog("[RecapGen] Step 7: CONFLICT — iCloud already has playlistId=\(existingPlaylistId)")
                let remoteExists = (try? await SubsonicAPIService.shared.getPlaylist(id: existingPlaylistId)) != nil
                if remoteExists {
                    CloudKitSyncService.recapLog("[RecapGen] Step 7a: iCloud playlistId exists on Navidrome — deleting own \(playlist.id), adopting \(existingPlaylistId)")
                    try? await SubsonicAPIService.shared.deletePlaylist(id: playlist.id)
                    entry = RecapRegistryRecord(
                        playlistId: existingPlaylistId,
                        serverId: serverId,
                        periodType: period.type.rawValue,
                        periodStart: period.start.timeIntervalSince1970,
                        periodEnd: period.end.timeIntervalSince1970,
                        ckRecordName: recordName,
                        isTest: isTest
                    )
                    resultTag = "CONFLICT_RESOLVED"
                    outcome = .adopted
                } else {
                    CloudKitSyncService.recapLog("[RecapGen] Step 7a: iCloud playlistId=\(existingPlaylistId) MISSING on Navidrome — overwriting stale marker with own \(playlist.id)")
                    await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: recordName)
                    if case .created = try? await CloudKitSyncService.shared.saveRecapMarker(entry, periodKey: period.periodKey) {
                        entry.ckRecordName = recordName
                    }
                    resultTag = "STALE_OVERWRITTEN"
                }
            }
        } else {
            CloudKitSyncService.recapLog("[RecapGen] Step 7: saveRecapMarker returned nil (iCloud disabled or error)")
        }

        CloudKitSyncService.recapLog("[RecapGen] Step 8: registerPlaylist (local DB)")
        await PlayLogService.shared.registerPlaylist(entry)
        CloudKitSyncService.recapLog("[RecapGen] Step 8: local DB written")

        CloudKitSyncService.recapLog("[RecapGen] Result: \(resultTag) — playlistId=\(entry.playlistId)")

        if !isTest {
            await enforceRetention(periodType: period.type, serverId: serverId)
        }
        return outcome
    }

    private func enforceRetention(periodType: RecapPeriod.PeriodType, serverId: String) async {
        let raw = UserDefaults.standard.integer(forKey: periodType.retentionKey)
        let limit = raw > 0 ? raw : periodType.defaultRetention

        let entries = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
            .filter { $0.periodType == periodType.rawValue && !$0.isTest }

        guard entries.count > limit else { return }

        let toDelete = entries.suffix(entries.count - limit)
        for entry in toDelete {
            CloudKitSyncService.debugLog("[Retention] deleting playlistId=\(entry.playlistId) marker=\(entry.ckRecordName ?? "nil") period=\(entry.periodType)/\(Date(timeIntervalSince1970: entry.periodStart))")
            try? await SubsonicAPIService.shared.deletePlaylist(id: entry.playlistId)
            if let ckName = entry.ckRecordName {
                await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: ckName)
            }
            await PlayLogService.shared.deleteRegistryEntry(playlistId: entry.playlistId)
        }
    }
}
