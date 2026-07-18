import Foundation
import CryptoKit

/// Gewählte Methode für den geräteübergreifenden Queue-Sync.
/// Persistiert via @AppStorage("queueSyncMode"). Bewusst exklusiv —
/// immer nur eine Quelle der Wahrheit aktiv.
nonisolated enum QueueSyncMode: String, CaseIterable, Sendable {
    /// Kein Sync.
    case off
    /// Subsonic `savePlayQueue`/`getPlayQueue` — interoperabel mit anderen Clients,
    /// aber konstruktionsbedingt nur eine flache Liste + aktueller Song + Position.
    case subsonic
    /// CloudKit — volle Shelv-Struktur (alle drei Queue-Arrays, Shuffle, Repeat),
    /// aber nur innerhalb des Apple-Ökosystems.
    case icloud
}

/// Vollständiger, geräteübergreifend übertragbarer Zustand der Wiedergabe-Queue.
///
/// Bei `QueueSyncMode.icloud` wird der komplette Snapshot JSON-codiert in einem
/// einzelnen CloudKit-Record abgelegt (volle Treue). Bei `QueueSyncMode.subsonic`
/// kann nur `queue` + `currentSongId` + `positionMs` übertragen werden — die
/// Play-Next-/User-Queue-Trennung und Shuffle/Repeat gehen dort verloren.
nonisolated struct QueueSnapshot: Codable, Equatable, Sendable {
    /// Normale Album-/Listen-Queue.
    var queue: [Song]
    /// Index des aktuellen Songs innerhalb von `queue`.
    var currentIndex: Int
    /// Höchstpriorisierte „Als nächstes"-Queue.
    var playNextQueue: [Song]
    /// Niedrigstpriorisierte User-Queue.
    var userQueue: [Song]

    /// Unverschobene Snapshots für die Shuffle-Wiederherstellung.
    var truthAlbumQueue: [Song]
    var truthPlayNextQueue: [Song]
    var truthUserQueue: [Song]

    /// ID des aktuell spielenden Songs (Quelle der Wahrheit für „welcher Song").
    var currentSongId: String?

    var isShuffled: Bool
    /// `RepeatMode.rawValue`.
    var repeatMode: String

    /// `SubsonicServer.stableId` — Queue ist serverScoped.
    var serverId: String
    /// Epoch-Sekunden des Schreibzeitpunkts (Debugging / Subsonic-`changed`-Abgleich).
    var changedAt: Double

    /// Clock-unabhängige Signatur des Queue-Inhalts: Hash über die Reihenfolge aller
    /// Song-IDs plus den aktuellen Song — **ohne** Position. Dadurch lösen reine
    /// Positions-Updates keinen „übernehmen?"-Prompt aus, und der Vergleich hängt
    /// nicht von Geräte-Uhren ab. Zwei Geräte mit identischem Inhalt erzeugen
    /// dieselbe Signatur.
    var signature: String {
        var canonical = queue.map(\.id).joined(separator: ",")
        canonical += "#" + playNextQueue.map(\.id).joined(separator: ",")
        canonical += "#" + userQueue.map(\.id).joined(separator: ",")
        canonical += "#" + (currentSongId ?? "")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Upload-Dedupe für iCloud: umfasst auch Playback-Metadaten, die im Prompt-Vergleich
    /// bewusst ignoriert werden. Dadurch können Repeat/Shuffle/Truth-Queue-Änderungen
    /// gespeichert werden, ohne reine Metadatenänderungen als fremde Queue anzubieten.
    var uploadFingerprint: String {
        let parts = [
            queue.map(\.id).joined(separator: ","),
            String(currentIndex),
            playNextQueue.map(\.id).joined(separator: ","),
            userQueue.map(\.id).joined(separator: ","),
            truthAlbumQueue.map(\.id).joined(separator: ","),
            truthPlayNextQueue.map(\.id).joined(separator: ","),
            truthUserQueue.map(\.id).joined(separator: ","),
            currentSongId ?? "",
            isShuffled ? "1" : "0",
            repeatMode
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "#").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Ob überhaupt ein wiederherstellbarer Inhalt vorliegt.
    var isEmpty: Bool {
        queue.isEmpty && playNextQueue.isEmpty && userQueue.isEmpty
    }

    /// Flache Repräsentation für Subsonic `savePlayQueue` (kennt nur eine Liste +
    /// aktueller Song): aktueller Song zuerst, dann die kommende Wiedergabe-Reihenfolge
    /// (Play-Next → Rest der Queue → User-Queue), Duplikate entfernt. Die Drei-Array-
    /// Struktur, Shuffle und Repeat gehen dabei bewusst verloren.
    ///
    /// Wichtig fürs Signatur-Bookkeeping: Up- und Download müssen für Subsonic
    /// **dieselbe** Repräsentation hashen, sonst würde die eigene Queue immer als
    /// „fremd" erkannt. Deshalb wird die Signatur in Subsonic-Modus über *diesen*
    /// abgeflachten Snapshot gebildet.
    func flattenedForSubsonic() -> QueueSnapshot {
        let current = (currentIndex >= 0 && currentIndex < queue.count) ? queue[currentIndex] : nil
        var flat: [Song] = []
        if let current { flat.append(current) }
        flat.append(contentsOf: playNextQueue)
        if currentIndex + 1 < queue.count {
            flat.append(contentsOf: queue[(currentIndex + 1)...])
        }
        flat.append(contentsOf: userQueue)
        var seen = Set<String>()
        flat = flat.filter { seen.insert($0.id).inserted }
        return QueueSnapshot(
            queue: flat,
            currentIndex: 0,
            playNextQueue: [],
            userQueue: [],
            truthAlbumQueue: [],
            truthPlayNextQueue: [],
            truthUserQueue: [],
            currentSongId: current?.id,
            isShuffled: isShuffled,
            repeatMode: repeatMode,
            serverId: serverId,
            changedAt: changedAt
        )
    }
}
