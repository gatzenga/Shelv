import Foundation

/// tvOS-Pendant zum plattformspezifischen DownloadStore (iOS/macOS haben je eine
/// echte Implementierung — bewusst nicht geteilt, siehe CLAUDE.md).
///
/// Apple TV bietet keine Downloads (kein garantierter persistenter Speicher,
/// Gerät ist immer am Netz). Der geteilte `DownloadService` ruft aber
/// `insertRecord`/`removeRecord` auf — dieser Stub erfüllt die Aufruffläche
/// als No-Op. Download-Flows werden auf tvOS nie angestoßen.
@MainActor
final class DownloadStore {
    static let shared = DownloadStore()
    private init() {}

    func enqueueSongs(_ songs: [Song]) {}
    func insertRecord(_ record: DownloadRecord) {}
    func removeRecord(songId: String, serverId: String) {}
}
