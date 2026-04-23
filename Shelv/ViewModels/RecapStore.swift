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

// MARK: - Processed-Weeks Registry
//
// Pro Woche ein Marker "diese Woche wurde bereits bearbeitet". Wird nur gesetzt,
// wenn `generate()` für diese Woche einen Erfolgs-Outcome liefert (created / adopted /
// skippedExistingEntry). Bleibt bestehen, auch wenn die Registry-Einträge später
// gelöscht werden (Swipe, Retention, Sync-Delete). Nur der Reset-Button und die
// Cleanup-Logik (Fenster > 10 Wochen) entfernen Einträge.

enum RecapProcessedWeeks {
    static let storageKey = "recap_processed_weeks"

    static func load() -> Set<Double> {
        let raw = UserDefaults.standard.array(forKey: storageKey) as? [Double] ?? []
        return Set(raw)
    }

    static func save(_ set: Set<Double>) {
        let cutoff = Date().addingTimeInterval(-10 * 7 * 24 * 3600).timeIntervalSince1970
        let trimmed = set.filter { $0 >= cutoff }
        UserDefaults.standard.set(Array(trimmed), forKey: storageKey)
    }

    static func insert(_ periodStart: Double) {
        var set = load()
        set.insert(periodStart)
        save(set)
    }

    static func remove(_ periodStart: Double) {
        var set = load()
        set.remove(periodStart)
        save(set)
    }

    static func contains(_ periodStart: Double) -> Bool {
        load().contains(periodStart)
    }
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
        if let entry, entry.periodType == RecapPeriod.PeriodType.week.rawValue, !entry.isTest {
            RecapProcessedWeeks.insert(entry.periodStart)
        }
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
            let importError = error.localizedDescription
            do {
                try await PlayLogService.shared.applyImportRollback()
                await PlayLogService.shared.cleanupImportRollback()
                await loadEntries(serverId: serverId)
                syncReports = [RecapSyncReport(
                    message: tr(
                        "Import failed — previous state restored.\n\(importError)",
                        "Import fehlgeschlagen — vorheriger Zustand wiederhergestellt.\n\(importError)"
                    ),
                    isError: true
                )]
            } catch let rollbackError {
                syncReports = [RecapSyncReport(
                    message: tr(
                        "Import failed and rollback failed. Backup preserved for manual recovery.\nImport: \(importError)\nRollback: \(rollbackError.localizedDescription)",
                        "Import fehlgeschlagen, Rollback fehlgeschlagen. Backup bleibt erhalten.\nImport: \(importError)\nRollback: \(rollbackError.localizedDescription)"
                    ),
                    isError: true
                )]
            }
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
                let basePart = "\(serverId.lowercased()).\(periodKey)"
                let recordName = entry.isTest ? "test.\(basePart)" : basePart
                var newEntry = RecapRegistryRecord(
                    playlistId: newPlaylist.id,
                    serverId: serverId,
                    periodType: entry.periodType,
                    periodStart: entry.periodStart,
                    periodEnd: entry.periodEnd,
                    ckRecordName: nil,
                    isTest: entry.isTest
                )
                if let result = try? await CloudKitSyncService.shared.saveRecapMarker(newEntry, periodKey: periodKey) {
                    switch result {
                    case .created:
                        newEntry.ckRecordName = recordName
                    case .conflict(let existingPlaylistId):
                        let remoteExists = (try? await api.getPlaylist(id: existingPlaylistId)) != nil
                        if remoteExists {
                            CloudKitSyncService.debugLog("[RecreateMissing] conflict: iCloud playlistId=\(existingPlaylistId) exists — adopting, discarding newly created \(newPlaylist.id)")
                            try? await api.deletePlaylist(id: newPlaylist.id)
                            newEntry = RecapRegistryRecord(
                                playlistId: existingPlaylistId,
                                serverId: serverId,
                                periodType: entry.periodType,
                                periodStart: entry.periodStart,
                                periodEnd: entry.periodEnd,
                                ckRecordName: recordName,
                                isTest: entry.isTest
                            )
                        } else {
                            CloudKitSyncService.debugLog("[RecreateMissing] conflict: iCloud playlistId=\(existingPlaylistId) MISSING on Navidrome — overwriting stale marker with new local \(newPlaylist.id)")
                            await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: recordName)
                            if case .created = try? await CloudKitSyncService.shared.saveRecapMarker(newEntry, periodKey: periodKey) {
                                newEntry.ckRecordName = recordName
                            }
                        }
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
            await PlayLogService.shared.cleanupImportRollback()
            await loadEntries(serverId: serverId)
        } catch {
            syncReports = [RecapSyncReport(message: error.localizedDescription, isError: true)]
            showSyncReport = true
        }
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
                    let basePart = "\(serverId.lowercased()).\(periodKey)"
                    let recordName = entry.isTest ? "test.\(basePart)" : basePart
                    var updatedEntry = RecapRegistryRecord(
                        playlistId: newPlaylist.id,
                        serverId: serverId,
                        periodType: entry.periodType,
                        periodStart: entry.periodStart,
                        periodEnd: entry.periodEnd,
                        ckRecordName: nil,
                        isTest: entry.isTest
                    )

                    if let markerResult = try? await CloudKitSyncService.shared.saveRecapMarker(updatedEntry, periodKey: periodKey) {
                        switch markerResult {
                        case .created:
                            updatedEntry.ckRecordName = recordName
                        case .conflict(let existingPlaylistId):
                            let remoteExists = (try? await api.getPlaylist(id: existingPlaylistId)) != nil
                            if remoteExists {
                                CloudKitSyncService.debugLog("[VerifyRepair] conflict: iCloud playlistId=\(existingPlaylistId) exists — adopting, discarding newly created \(newPlaylist.id)")
                                try? await api.deletePlaylist(id: newPlaylist.id)
                                updatedEntry = RecapRegistryRecord(
                                    playlistId: existingPlaylistId,
                                    serverId: serverId,
                                    periodType: entry.periodType,
                                    periodStart: entry.periodStart,
                                    periodEnd: entry.periodEnd,
                                    ckRecordName: recordName,
                                    isTest: entry.isTest
                                )
                            } else {
                                CloudKitSyncService.debugLog("[VerifyRepair] conflict: iCloud playlistId=\(existingPlaylistId) MISSING on Navidrome — overwriting stale marker with new local \(newPlaylist.id)")
                                await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: recordName)
                                if case .created = try? await CloudKitSyncService.shared.saveRecapMarker(updatedEntry, periodKey: periodKey) {
                                    updatedEntry.ckRecordName = recordName
                                }
                            }
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
            let basePart = "\(serverId.lowercased()).\(periodKey)"
            let recordName = diff.entry.isTest ? "test.\(basePart)" : basePart

            var newEntry = RecapRegistryRecord(
                playlistId: newPlaylist.id,
                serverId: serverId,
                periodType: diff.entry.periodType,
                periodStart: diff.entry.periodStart,
                periodEnd: diff.entry.periodEnd,
                ckRecordName: nil,
                isTest: diff.entry.isTest
            )

            if let markerResult = try? await CloudKitSyncService.shared.saveRecapMarker(newEntry, periodKey: periodKey) {
                switch markerResult {
                case .created:
                    newEntry.ckRecordName = recordName
                case .conflict(let existingPlaylistId):
                    let remoteExists = (try? await api.getPlaylist(id: existingPlaylistId)) != nil
                    if remoteExists {
                        CloudKitSyncService.debugLog("[ApplyDiff] conflict: iCloud playlistId=\(existingPlaylistId) exists — adopting, discarding newly created \(newPlaylist.id)")
                        try? await api.deletePlaylist(id: newPlaylist.id)
                        newEntry = RecapRegistryRecord(
                            playlistId: existingPlaylistId,
                            serverId: serverId,
                            periodType: diff.entry.periodType,
                            periodStart: diff.entry.periodStart,
                            periodEnd: diff.entry.periodEnd,
                            ckRecordName: recordName,
                            isTest: diff.entry.isTest
                        )
                    } else {
                        CloudKitSyncService.debugLog("[ApplyDiff] conflict: iCloud playlistId=\(existingPlaylistId) MISSING on Navidrome — overwriting stale marker with new local \(newPlaylist.id)")
                        await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: recordName)
                        if case .created = try? await CloudKitSyncService.shared.saveRecapMarker(newEntry, periodKey: periodKey) {
                            newEntry.ckRecordName = recordName
                        }
                    }
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
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let now = Date()
        guard let start = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return false }
        let period = RecapPeriod(type: .week, start: start, end: now)
        do {
            _ = try await RecapGenerator.shared.generate(period: period, serverId: serverId, trigger: "test-button", isTest: true)
            await loadEntries(serverId: serverId)
        } catch {
            generationError = error.localizedDescription
        }
        return entries.count > before
    }

    func deleteEntry(playlistId: String, serverId: String) async {
        let entry = await PlayLogService.shared.registryEntry(playlistId: playlistId)
        CloudKitSyncService.debugLog("[UserAction:deleteEntry] playlistId=\(playlistId) marker=\(entry?.ckRecordName ?? "nil")")
        if let entry, entry.periodType == RecapPeriod.PeriodType.week.rawValue, !entry.isTest {
            RecapProcessedWeeks.insert(entry.periodStart)
        }
        try? await SubsonicAPIService.shared.deletePlaylist(id: playlistId)
        await PlayLogService.shared.deleteRegistryEntry(playlistId: playlistId)
        if let ckName = entry?.ckRecordName {
            await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: ckName)
        }
        await loadEntries(serverId: serverId)
    }

    /// Löscht den neuesten non-test Week-Recap für den Server vollständig (Navidrome + iCloud + DB)
    /// und entfernt seinen Processed-Marker. Triggert keine Auto-Generation.
    /// `true` = Eintrag gefunden und gelöscht, `false` = kein Eintrag vorhanden.
    @discardableResult
    func resetLastWeek(serverId: String) async -> Bool {
        let all = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        if let target = all.first(where: { $0.periodType == RecapPeriod.PeriodType.week.rawValue && !$0.isTest }) {
            CloudKitSyncService.debugLog("[UserAction:resetLastWeek] playlistId=\(target.playlistId) marker=\(target.ckRecordName ?? "nil") period=\(target.periodStart)")
            try? await SubsonicAPIService.shared.deletePlaylist(id: target.playlistId)
            if let ckName = target.ckRecordName {
                await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: ckName)
            }
            await PlayLogService.shared.deleteRegistryEntry(playlistId: target.playlistId)
            RecapProcessedWeeks.remove(target.periodStart)
            await loadEntries(serverId: serverId)
            return true
        }

        CloudKitSyncService.debugLog("[UserAction:resetLastWeek] no weekly registry entry found — clearing lastWeek marker")
        if let lastWeek = RecapPeriod.lastWeek() {
            RecapProcessedWeeks.remove(lastWeek.start.timeIntervalSince1970)
        }
        return false
    }

    @discardableResult
    func resetLastMonth(serverId: String) async -> Bool {
        await resetSinglePeriod(
            serverId: serverId,
            periodType: .month,
            genKey: GenKey.lastMonth,
            fallback: RecapPeriod.lastMonth(),
            logTag: "[UserAction:resetLastMonth]"
        )
    }

    @discardableResult
    func resetLastYear(serverId: String) async -> Bool {
        await resetSinglePeriod(
            serverId: serverId,
            periodType: .year,
            genKey: GenKey.lastYear,
            fallback: RecapPeriod.lastYear(),
            logTag: "[UserAction:resetLastYear]"
        )
    }

    private func resetSinglePeriod(
        serverId: String,
        periodType: RecapPeriod.PeriodType,
        genKey: String,
        fallback: RecapPeriod?,
        logTag: String
    ) async -> Bool {
        let all = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
        if let target = all.first(where: { $0.periodType == periodType.rawValue && !$0.isTest }) {
            CloudKitSyncService.debugLog("\(logTag) playlistId=\(target.playlistId) marker=\(target.ckRecordName ?? "nil") period=\(target.periodStart)")
            try? await SubsonicAPIService.shared.deletePlaylist(id: target.playlistId)
            if let ckName = target.ckRecordName {
                await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: ckName)
            }
            await PlayLogService.shared.deleteRegistryEntry(playlistId: target.playlistId)
            UserDefaults.standard.removeObject(forKey: genKey)
            await loadEntries(serverId: serverId)
            return true
        }
        CloudKitSyncService.debugLog("\(logTag) no registry entry — clearing UserDefault")
        UserDefaults.standard.removeObject(forKey: genKey)
        _ = fallback
        return false
    }

    func excessRetentionCount(periodType: RecapPeriod.PeriodType, limit: Int, serverId: String) async -> Int {
        let all = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
            .filter { $0.periodType == periodType.rawValue }
        return max(0, all.count - limit)
    }

    func applyRetention(periodType: RecapPeriod.PeriodType, limit: Int, serverId: String) async {
        let all = await PlayLogService.shared.allRegistryEntries(serverId: serverId)
            .filter { $0.periodType == periodType.rawValue }
        guard all.count > limit else { return }
        let toDelete = all.suffix(all.count - limit)
        for entry in toDelete {
            CloudKitSyncService.debugLog("[Retention:manual] deleting playlistId=\(entry.playlistId) marker=\(entry.ckRecordName ?? "nil") period=\(entry.periodType)")
            try? await SubsonicAPIService.shared.deletePlaylist(id: entry.playlistId)
            if let ckName = entry.ckRecordName {
                await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: ckName)
            }
            await PlayLogService.shared.deleteRegistryEntry(playlistId: entry.playlistId)
        }
        await loadEntries(serverId: serverId)
    }

    private func generatePendingPeriods(serverId: String) async {
        isGenerating = true
        defer { isGenerating = false }

        CloudKitSyncService.recapLog("[RecapGen] ══ Auto-trigger check ══")

        let defaults = UserDefaults.standard

        if defaults.bool(forKey: "recapWeeklyEnabled") {
            await processWeeklyBackfill(serverId: serverId)
        } else {
            CloudKitSyncService.recapLog("[RecapGen] Weekly: disabled")
        }

        await processSingleShot(
            label: "Monthly",
            enabled: defaults.bool(forKey: "recapMonthlyEnabled"),
            period: RecapPeriod.lastMonth(),
            genKey: GenKey.lastMonth,
            graceHours: RecapPeriod.PeriodType.monthGraceHours,
            serverId: serverId
        )
        await processSingleShot(
            label: "Yearly",
            enabled: defaults.bool(forKey: "recapYearlyEnabled"),
            period: RecapPeriod.lastYear(),
            genKey: GenKey.lastYear,
            graceHours: RecapPeriod.PeriodType.yearGraceHours,
            serverId: serverId
        )
    }

    private func processWeeklyBackfill(serverId: String) async {
        guard let mostRecent = RecapPeriod.lastWeek() else {
            CloudKitSyncService.recapLog("[RecapGen] Weekly: period calculation failed")
            return
        }

        let graceHours = RecapPeriod.PeriodType.weekGraceHours
        let graceDeadline = mostRecent.end.addingTimeInterval(Double(graceHours) * 3600)
        guard Date() >= graceDeadline else {
            let hoursLeft = max(0, graceDeadline.timeIntervalSinceNow / 3600)
            CloudKitSyncService.recapLog("[RecapGen] Weekly \(mostRecent.periodKey): grace not passed (\(String(format: "%.1f", hoursLeft))h remaining)")
            return
        }

        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        var candidates: [RecapPeriod] = [mostRecent]
        var current = mostRecent
        for _ in 0..<3 {
            guard
                let prevStart = cal.date(byAdding: .weekOfYear, value: -1, to: current.start),
                let prevEnd   = cal.date(byAdding: .second, value: -1, to: current.start)
            else { break }
            current = RecapPeriod(type: .week, start: prevStart, end: prevEnd)
            candidates.append(current)
        }
        candidates.sort { $0.start < $1.start }

        var processed = RecapProcessedWeeks.load()
        let initial = processed
        CloudKitSyncService.recapLog("[RecapGen] Weekly: \(candidates.count) week(s) in window: \(candidates.map { $0.periodKey }.joined(separator: ", "))")

        for week in candidates {
            let ts = week.start.timeIntervalSince1970
            if processed.contains(ts) {
                logAlreadyProcessed(period: week, serverId: serverId, trigger: "auto:week")
                continue
            }
            do {
                let outcome = try await RecapGenerator.shared.generate(
                    period: week, serverId: serverId, trigger: "auto:week"
                )
                switch outcome {
                case .skippedNoPlays:
                    CloudKitSyncService.recapLog("[RecapGen] Weekly \(week.periodKey): no plays — will retry next run")
                case .created, .adopted, .skippedExistingEntry:
                    processed.insert(ts)
                    CloudKitSyncService.recapLog("[RecapGen] Weekly \(week.periodKey): marked processed")
                }
            } catch {
                generationError = error.localizedDescription
            }
        }

        if processed != initial {
            RecapProcessedWeeks.save(processed)
        }
    }

    private func logAlreadyProcessed(period: RecapPeriod, serverId: String, trigger: String) {
        let recordName = "\(serverId.lowercased()).\(period.periodKey)"
        CloudKitSyncService.recapLog("[RecapGen] ── Trigger: \(trigger) (already processed) ──")
        CloudKitSyncService.recapLog("[RecapGen] Period: \(period.type.rawValue) \(period.playlistName)")
        CloudKitSyncService.recapLog("[RecapGen] periodKey: \(period.periodKey)")
        CloudKitSyncService.recapLog("[RecapGen] recordName: \(recordName)")
        CloudKitSyncService.recapLog("[RecapGen] Result: SKIPPED — already processed (marker set)")
    }

    private func processSingleShot(
        label: String,
        enabled: Bool,
        period: RecapPeriod?,
        genKey: String,
        graceHours: Int,
        serverId: String
    ) async {
        guard enabled else {
            CloudKitSyncService.recapLog("[RecapGen] \(label): disabled")
            return
        }
        guard let period else {
            CloudKitSyncService.recapLog("[RecapGen] \(label): period calculation failed")
            return
        }
        let defaults = UserDefaults.standard
        let lastGen = defaults.double(forKey: genKey)
        let graceDeadline = period.end.addingTimeInterval(Double(graceHours) * 3600)
        let periodFresh = period.start.timeIntervalSince1970 > lastGen
        let gracePassed = Date() >= graceDeadline

        if !periodFresh {
            logAlreadyProcessed(period: period, serverId: serverId, trigger: "auto:\(period.type.rawValue)")
            return
        }
        if !gracePassed {
            let hoursLeft = max(0, graceDeadline.timeIntervalSinceNow / 3600)
            CloudKitSyncService.recapLog("[RecapGen] \(label) \(period.periodKey): grace not passed (\(String(format: "%.1f", hoursLeft))h remaining)")
            return
        }
        do {
            let outcome = try await RecapGenerator.shared.generate(
                period: period, serverId: serverId, trigger: "auto:\(period.type.rawValue)"
            )
            switch outcome {
            case .created, .adopted, .skippedExistingEntry:
                defaults.set(period.start.timeIntervalSince1970, forKey: genKey)
            case .skippedNoPlays:
                CloudKitSyncService.recapLog("[RecapGen] \(label) \(period.periodKey): no plays — will retry next run")
            }
        } catch {
            generationError = error.localizedDescription
        }
    }
}
