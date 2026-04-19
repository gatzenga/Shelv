import Foundation
import SwiftUI
import Combine

// MARK: - Sync Report

struct RecapSyncReport: Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

// MARK: - Recap Diff

struct RecapDiff: Identifiable {
    let id = UUID()
    let entry: RecapRegistryRecord
    let playlistName: String
    let currentName: String
    let currentComment: String?
    let expectedOrder: [Song]
    let currentOrder: [Song]
    let missingSongs: [Song]
    let extraSongs: [Song]
    let orderChanged: Bool
    let nameMismatch: Bool
    let commentMissing: Bool
    let serverMissing: Bool

    var hasAnyDiff: Bool {
        serverMissing || !missingSongs.isEmpty || !extraSongs.isEmpty || orderChanged || nameMismatch || commentMissing
    }
}

enum RecapDiffDecision {
    case update
    case createNew
}

// MARK: - RecapStore

@MainActor
class RecapStore: ObservableObject {
    @Published var isGenerating: Bool = false
    @Published var generationError: String?
    @Published var syncReports: [RecapSyncReport] = []
    @Published var showSyncReport: Bool = false
    @Published var entries: [RecapRegistryRecord] = []
    @Published var recapPlaylistIds: Set<String> = []
    @Published var isImporting: Bool = false

    private enum GenKey {
        static let lastWeek  = "recap_last_gen_week"
        static let lastMonth = "recap_last_gen_month"
        static let lastYear  = "recap_last_gen_year"
    }

    // MARK: - Setup

    func setup(serverId: String) async {
        await loadEntries(serverId: serverId)
        guard UserDefaults.standard.bool(forKey: "recapEnabled") else { return }
        await generatePendingPeriods(serverId: serverId)
    }

    func loadEntries(serverId: String) async {
        let all = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        entries = all
        recapPlaylistIds = Set(all.map { $0.playlistId })
    }

    func refreshWithCleanup(serverId: String) async {
        await loadEntries(serverId: serverId)
    }

    func deleteRegistryEntryOnly(playlistId: String, serverId: String) async {
        let entry = await PlayLogService.shared.registryEntry(playlistId: playlistId)
        CloudKitSyncService.debugLog("[UserAction:registryOnly] playlistId=\(playlistId) marker=\(entry?.ckRecordName ?? "nil")")
        if let ckName = entry?.ckRecordName {
            await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: ckName)
        }
        await PlayLogService.shared.deleteRegistryEntry(playlistId: playlistId)
        await loadEntries(serverId: serverId)
    }

    // MARK: - Recap Playlist Check

    func isRecapPlaylist(id: String) async -> Bool {
        await PlayLogService.shared.isRecapPlaylist(playlistId: id)
    }

    // MARK: - Export

    var dbFileURL: URL { PlayLogService.dbURL }

    func exportBackupURL() async throws -> URL {
        try await PlayLogService.shared.makeExportBackup()
    }

    // MARK: - Import + Verify

    func importDatabase(from url: URL, serverId: String) async {
        isImporting = true
        defer { isImporting = false }

        let dest = PlayLogService.dbURL
        do {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            try await PlayLogService.shared.createImportRollback()
            await PlayLogService.shared.shutdown()

            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            for suffix in ["", "-wal", "-shm"] {
                let path = dest.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            try FileManager.default.copyItem(at: url, to: dest)

            await PlayLogService.shared.setup()
            await PlayLogService.shared.rewriteAllServerIds(to: serverId)
            await CloudKitSyncService.shared.resetChangeToken()
            await CloudKitSyncService.shared.syncNow()
            await recreateMissingPlaylists(serverId: serverId)
            await loadEntries(serverId: serverId)
            await PlayLogService.shared.cleanupImportRollback()

            syncReports = [RecapSyncReport(
                message: tr("Import finished", "Import abgeschlossen"),
                isError: false
            )]
            showSyncReport = true
            NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
        } catch {
            await PlayLogService.shared.cleanupImportRollback()
            syncReports = [RecapSyncReport(message: error.localizedDescription, isError: true)]
            showSyncReport = true
        }
    }

    private func recreateMissingPlaylists(serverId: String) async {
        let api = SubsonicAPIService.shared
        let entries = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        for entry in entries {
            guard (try? await api.getPlaylist(id: entry.playlistId)) == nil else { continue }
            guard let type = RecapPeriod.PeriodType(rawValue: entry.periodType) else { continue }
            let periodStart = Date(timeIntervalSince1970: entry.periodStart)
            let periodEnd   = Date(timeIntervalSince1970: entry.periodEnd)
            let period = RecapPeriod(type: type, start: periodStart, end: periodEnd)

            let expectedIds = await PlayLogService.shared.topSongs(
                serverId: serverId, from: periodStart, to: periodEnd, limit: type.songLimit
            ).map(\.songId)
            guard !expectedIds.isEmpty else { continue }

            do {
                let newPlaylist = try await api.createPlaylist(
                    name: period.playlistName,
                    songIds: expectedIds,
                    comment: "Shelv Recap"
                )

                if let oldCkName = entry.ckRecordName {
                    await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: oldCkName)
                }
                await PlayLogService.shared.deleteRegistryEntry(playlistId: entry.playlistId)

                let periodKey = period.periodKey
                let recordName = "\(serverId.lowercased()).\(periodKey)"
                var newEntry = RecapRegistryRecord(
                    playlistId: newPlaylist.id,
                    serverId: serverId,
                    periodType: entry.periodType,
                    periodStart: entry.periodStart,
                    periodEnd: entry.periodEnd,
                    ckRecordName: nil
                )
                if let result = try? await CloudKitSyncService.shared.saveRecapMarker(newEntry, periodKey: periodKey) {
                    switch result {
                    case .created:
                        newEntry.ckRecordName = recordName
                    case .conflict(let existingPlaylistId):
                        try? await api.deletePlaylist(id: newPlaylist.id)
                        newEntry = RecapRegistryRecord(
                            playlistId: existingPlaylistId,
                            serverId: serverId,
                            periodType: entry.periodType,
                            periodStart: entry.periodStart,
                            periodEnd: entry.periodEnd,
                            ckRecordName: recordName
                        )
                    }
                }
                await PlayLogService.shared.registerPlaylist(newEntry)
            } catch {
                continue
            }
        }
    }

    func cancelImport(serverId: String) async {
        do {
            try await PlayLogService.shared.applyImportRollback()
            await loadEntries(serverId: serverId)
        } catch {
            syncReports = [RecapSyncReport(message: error.localizedDescription, isError: true)]
            showSyncReport = true
        }
        await PlayLogService.shared.cleanupImportRollback()
    }

    func completeImport() async {
        await PlayLogService.shared.cleanupImportRollback()
    }

    func verifyAndRepair(serverId: String) async {
        isGenerating = true
        defer { isGenerating = false }

        let api = SubsonicAPIService.shared
        let entries = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        var reports: [RecapSyncReport] = []

        for entry in entries {
            guard let type = RecapPeriod.PeriodType(rawValue: entry.periodType) else { continue }
            let periodStart = Date(timeIntervalSince1970: entry.periodStart)
            let periodEnd   = Date(timeIntervalSince1970: entry.periodEnd)
            let period = RecapPeriod(type: type, start: periodStart, end: periodEnd)
            let name = period.playlistName

            // Prüfen ob Playlist noch existiert
            if let currentPlaylist = try? await api.getPlaylist(id: entry.playlistId) {
                let currentIds = (currentPlaylist.songs ?? []).map { $0.id }
                let expected   = await PlayLogService.shared.topSongs(
                    serverId: serverId, from: periodStart, to: periodEnd, limit: type.songLimit
                ).map { $0.songId }

                guard expected != currentIds else { continue }

                // Reorder: alle alten Indizes entfernen + neue hinzufügen
                let removeIndices = Array(0..<currentIds.count)
                do {
                    try await api.updatePlaylist(
                        id: entry.playlistId,
                        songIdsToAdd: expected,
                        songIndicesToRemove: removeIndices
                    )
                    // Prüfen welche Songs tatsächlich hinzugefügt wurden
                    if let updated = try? await api.getPlaylist(id: entry.playlistId) {
                        let addedIds = Set((updated.songs ?? []).map { $0.id })
                        let notFound = expected.filter { !addedIds.contains($0) }
                        for songId in notFound {
                            reports.append(RecapSyncReport(
                                message: tr("Song not found on server: \(songId)", "Song nicht gefunden: \(songId)"),
                                isError: true
                            ))
                        }
                    }
                    reports.append(RecapSyncReport(
                        message: tr("\"\(name)\" updated", "\"\(name)\" aktualisiert"),
                        isError: false
                    ))
                } catch {
                    reports.append(RecapSyncReport(message: error.localizedDescription, isError: true))
                }

            } else {
                let expected = await PlayLogService.shared.topSongs(
                    serverId: serverId, from: periodStart, to: periodEnd, limit: type.songLimit
                ).map { $0.songId }
                guard !expected.isEmpty else { continue }

                do {
                    let newPlaylist = try await api.createPlaylist(name: name, songIds: expected, comment: "Shelv Recap")

                    if let oldCkName = entry.ckRecordName {
                        await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: oldCkName)
                    }
                    await PlayLogService.shared.deleteRegistryEntry(playlistId: entry.playlistId)

                    let periodKey = period.periodKey
                    let recordName = "\(serverId.lowercased()).\(periodKey)"
                    var updatedEntry = RecapRegistryRecord(
                        playlistId: newPlaylist.id,
                        serverId: serverId,
                        periodType: entry.periodType,
                        periodStart: entry.periodStart,
                        periodEnd: entry.periodEnd,
                        ckRecordName: nil
                    )

                    if let markerResult = try? await CloudKitSyncService.shared.saveRecapMarker(updatedEntry, periodKey: periodKey) {
                        switch markerResult {
                        case .created:
                            updatedEntry.ckRecordName = recordName
                        case .conflict(let existingPlaylistId):
                            try? await api.deletePlaylist(id: newPlaylist.id)
                            updatedEntry = RecapRegistryRecord(
                                playlistId: existingPlaylistId,
                                serverId: serverId,
                                periodType: entry.periodType,
                                periodStart: entry.periodStart,
                                periodEnd: entry.periodEnd,
                                ckRecordName: recordName
                            )
                        }
                    }

                    await PlayLogService.shared.registerPlaylist(updatedEntry)
                    reports.append(RecapSyncReport(
                        message: tr("\"\(name)\" recreated", "\"\(name)\" neu erstellt"),
                        isError: false
                    ))
                } catch {
                    reports.append(RecapSyncReport(message: error.localizedDescription, isError: true))
                }
            }
        }

        if reports.isEmpty {
            reports.append(RecapSyncReport(
                message: tr("All playlists up to date", "Alle Playlists aktuell"),
                isError: false
            ))
        }

        await loadEntries(serverId: serverId)
        syncReports = reports
        showSyncReport = true
    }

    // MARK: - Diff Computation

    func computeDiffs(serverId: String) async -> [RecapDiff] {
        isGenerating = true
        defer { isGenerating = false }

        let api = SubsonicAPIService.shared
        let entries = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        var diffs: [RecapDiff] = []

        for entry in entries {
            guard let type = RecapPeriod.PeriodType(rawValue: entry.periodType) else { continue }
            let periodStart = Date(timeIntervalSince1970: entry.periodStart)
            let periodEnd   = Date(timeIntervalSince1970: entry.periodEnd)
            let period = RecapPeriod(type: type, start: periodStart, end: periodEnd)

            let expectedIds = await PlayLogService.shared.topSongs(
                serverId: serverId, from: periodStart, to: periodEnd, limit: type.songLimit
            ).map(\.songId)

            let current = try? await api.getPlaylist(id: entry.playlistId)

            if current == nil {
                guard !expectedIds.isEmpty else { continue }
                var expectedSongs: [Song] = []
                for id in expectedIds {
                    if let song = try? await api.getSong(id: id) {
                        expectedSongs.append(song)
                    } else {
                        expectedSongs.append(placeholderSong(id: id))
                    }
                }
                diffs.append(RecapDiff(
                    entry: entry,
                    playlistName: period.playlistName,
                    currentName: "",
                    currentComment: nil,
                    expectedOrder: expectedSongs,
                    currentOrder: [],
                    missingSongs: expectedSongs,
                    extraSongs: [],
                    orderChanged: false,
                    nameMismatch: false,
                    commentMissing: false,
                    serverMissing: true
                ))
                continue
            }

            let currentSongs = current!.songs ?? []
            let currentIds   = currentSongs.map(\.id)
            let currentName  = current!.name
            let currentComment = current!.comment

            let nameMismatch    = currentName != period.playlistName
            let commentMissing  = (currentComment ?? "") != "Shelv Recap"
            let contentMismatch = currentIds != expectedIds

            guard contentMismatch || nameMismatch || commentMissing else { continue }

            let currentIdSet  = Set(currentIds)
            let expectedIdSet = Set(expectedIds)
            let missingIds    = expectedIds.filter { !currentIdSet.contains($0) }
            let extraIds      = currentIds.filter { !expectedIdSet.contains($0) }

            var missingSongs: [Song] = []
            for id in missingIds {
                if let song = try? await api.getSong(id: id) {
                    missingSongs.append(song)
                } else {
                    missingSongs.append(placeholderSong(id: id))
                }
            }

            let extraSongs = currentSongs.filter { !expectedIdSet.contains($0.id) }

            var idToSong: [String: Song] = [:]
            for song in currentSongs { idToSong[song.id] = song }
            for song in missingSongs { idToSong[song.id] = song }
            let expectedOrder = expectedIds.compactMap { idToSong[$0] }

            let orderChanged = missingIds.isEmpty && extraIds.isEmpty && contentMismatch

            let diff = RecapDiff(
                entry: entry,
                playlistName: period.playlistName,
                currentName: currentName,
                currentComment: currentComment,
                expectedOrder: expectedOrder,
                currentOrder: currentSongs,
                missingSongs: missingSongs,
                extraSongs: extraSongs,
                orderChanged: orderChanged,
                nameMismatch: nameMismatch,
                commentMissing: commentMissing,
                serverMissing: false
            )

            if diff.hasAnyDiff { diffs.append(diff) }
        }

        return diffs
    }

    private func placeholderSong(id: String) -> Song {
        Song(
            id: id, title: id, artist: nil, album: nil, albumId: nil,
            track: nil, duration: nil, coverArt: nil, year: nil, genre: nil,
            playCount: nil, starred: nil, suffix: nil, bitRate: nil
        )
    }

    func applyDiff(_ diff: RecapDiff, decision: RecapDiffDecision, serverId: String) async throws {
        let api = SubsonicAPIService.shared
        let expectedIds = diff.expectedOrder.map(\.id)

        switch decision {
        case .update:
            guard !diff.serverMissing else {
                throw NSError(domain: "RecapStore", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Playlist no longer exists on server"])
            }
            let contentDiffers = !diff.missingSongs.isEmpty || !diff.extraSongs.isEmpty || diff.orderChanged
            try await api.updatePlaylist(
                id: diff.entry.playlistId,
                name: diff.nameMismatch ? diff.playlistName : nil,
                comment: diff.commentMissing ? "Shelv Recap" : nil,
                songIdsToAdd: contentDiffers ? expectedIds : [],
                songIndicesToRemove: contentDiffers ? Array(0..<diff.currentOrder.count) : []
            )
        case .createNew:
            guard !expectedIds.isEmpty else {
                throw NSError(domain: "RecapStore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No songs to create playlist"])
            }
            let newPlaylist = try await api.createPlaylist(
                name: diff.playlistName,
                songIds: expectedIds,
                comment: "Shelv Recap"
            )

            if let oldCkName = diff.entry.ckRecordName {
                await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: oldCkName)
            }
            await PlayLogService.shared.deleteRegistryEntry(playlistId: diff.entry.playlistId)

            guard let type = RecapPeriod.PeriodType(rawValue: diff.entry.periodType) else {
                throw NSError(domain: "RecapStore", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid period type"])
            }
            let period = RecapPeriod(
                type: type,
                start: Date(timeIntervalSince1970: diff.entry.periodStart),
                end: Date(timeIntervalSince1970: diff.entry.periodEnd)
            )
            let periodKey = period.periodKey
            let recordName = "\(serverId.lowercased()).\(periodKey)"

            var newEntry = RecapRegistryRecord(
                playlistId: newPlaylist.id,
                serverId: serverId,
                periodType: diff.entry.periodType,
                periodStart: diff.entry.periodStart,
                periodEnd: diff.entry.periodEnd,
                ckRecordName: nil
            )

            if let markerResult = try? await CloudKitSyncService.shared.saveRecapMarker(newEntry, periodKey: periodKey) {
                switch markerResult {
                case .created:
                    newEntry.ckRecordName = recordName
                case .conflict(let existingPlaylistId):
                    try? await api.deletePlaylist(id: newPlaylist.id)
                    newEntry = RecapRegistryRecord(
                        playlistId: existingPlaylistId,
                        serverId: serverId,
                        periodType: diff.entry.periodType,
                        periodStart: diff.entry.periodStart,
                        periodEnd: diff.entry.periodEnd,
                        ckRecordName: recordName
                    )
                }
            }

            await PlayLogService.shared.registerPlaylist(newEntry)
            await loadEntries(serverId: serverId)
        }
    }

    // MARK: - Generation

    // MARK: - Test Generation

    /// Gibt `true` zurück wenn eine Playlist erstellt wurde, `false` wenn keine Plays vorhanden.
    func generateTest(serverId: String) async -> Bool {
        isGenerating = true
        defer { isGenerating = false }
        let before = entries.count
        let now = Date()
        let start = now.addingTimeInterval(-7 * 24 * 3600)
        let period = RecapPeriod(type: .week, start: start, end: now.addingTimeInterval(1))
        do {
            try await RecapGenerator.shared.generate(period: period, serverId: serverId)
            await loadEntries(serverId: serverId)
        } catch {
            generationError = error.localizedDescription
        }
        return entries.count > before
    }

    func deleteEntry(playlistId: String, serverId: String) async {
        let entry = await PlayLogService.shared.registryEntry(playlistId: playlistId)
        CloudKitSyncService.debugLog("[UserAction:deleteEntry] playlistId=\(playlistId) marker=\(entry?.ckRecordName ?? "nil")")
        try? await SubsonicAPIService.shared.deletePlaylist(id: playlistId)
        await PlayLogService.shared.deleteRegistryEntry(playlistId: playlistId)
        if let ckName = entry?.ckRecordName {
            await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: ckName)
        }
        await loadEntries(serverId: serverId)
    }

    private func generatePendingPeriods(serverId: String) async {
        isGenerating = true
        defer { isGenerating = false }

        let defaults = UserDefaults.standard
        var tasks: [(RecapPeriod, String)] = []

        if defaults.bool(forKey: "recapWeeklyEnabled"),
           let period = RecapPeriod.lastWeek() {
            let lastGen = defaults.double(forKey: GenKey.lastWeek)
            let graceDeadline = period.end.addingTimeInterval(Double(RecapPeriod.PeriodType.weekGraceHours) * 3600)
            if period.start.timeIntervalSince1970 > lastGen, Date() >= graceDeadline {
                tasks.append((period, GenKey.lastWeek))
            }
        }

        if defaults.bool(forKey: "recapMonthlyEnabled"),
           let period = RecapPeriod.lastMonth() {
            let lastGen = defaults.double(forKey: GenKey.lastMonth)
            let graceDeadline = period.end.addingTimeInterval(Double(RecapPeriod.PeriodType.monthGraceHours) * 3600)
            if period.start.timeIntervalSince1970 > lastGen, Date() >= graceDeadline {
                tasks.append((period, GenKey.lastMonth))
            }
        }

        if defaults.bool(forKey: "recapYearlyEnabled"),
           let period = RecapPeriod.lastYear() {
            let lastGen = defaults.double(forKey: GenKey.lastYear)
            let graceDeadline = period.end.addingTimeInterval(Double(RecapPeriod.PeriodType.yearGraceHours) * 3600)
            if period.start.timeIntervalSince1970 > lastGen, Date() >= graceDeadline {
                tasks.append((period, GenKey.lastYear))
            }
        }

        for (period, genKey) in tasks {
            do {
                try await RecapGenerator.shared.generate(period: period, serverId: serverId)
                defaults.set(period.start.timeIntervalSince1970, forKey: genKey)
            } catch {
                generationError = error.localizedDescription
            }
        }
    }
}
