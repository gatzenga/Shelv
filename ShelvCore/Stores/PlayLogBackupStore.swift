import Combine
import Foundation

nonisolated struct PlayLogBackupReport: Identifiable, Sendable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// Export and import of the play history database.
///
/// The play log is the listening history the smart mixes are built from, so it
/// is worth being able to carry between devices and back up.
@MainActor
final class PlayLogBackupStore: ObservableObject {
    static let shared = PlayLogBackupStore()

    @Published var isImporting = false
    @Published var reports: [PlayLogBackupReport] = []
    @Published var showReport = false

    private init() {}

    var dbFileURL: URL { PlayLogService.dbURL }

    func exportBackupURL() async throws -> URL {
        try await PlayLogService.shared.makeExportBackup()
    }

    func importDatabase(from url: URL, serverId: String) async {
        isImporting = true
        defer { isImporting = false }

        do {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            try await PlayLogService.shared.replaceDatabaseFromImport(
                sourceURL: url,
                serverId: serverId
            )
            await CloudKitSyncService.shared.resetChangeToken()
            await CloudKitSyncService.shared.syncNow()

            reports = [PlayLogBackupReport(
                message: String(localized: "import_finished"),
                isError: false
            )]
        } catch let error as PlayLogImportError {
            switch error {
            case .restored(let importMessage):
                reports = [PlayLogBackupReport(
                    message: String(
                        format: String(localized: "import_failed_restored_format"),
                        importMessage
                    ),
                    isError: true
                )]
            case .rollbackFailed(let importMessage, let rollbackMessage):
                reports = [PlayLogBackupReport(
                    message: String(
                        format: String(localized: "import_rollback_failed_format"),
                        importMessage,
                        rollbackMessage
                    ),
                    isError: true
                )]
            }
        } catch {
            reports = [PlayLogBackupReport(
                message: String(
                    format: String(localized: "import_failed_restored_format"),
                    error.localizedDescription
                ),
                isError: true
            )]
        }
        showReport = true
    }
}
