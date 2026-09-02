import Foundation

/// Ergebnis eines Lookups einer Song-ID beim Server.
nonisolated enum PlayLogIdLookupResult: Equatable, Sendable {
    case found(title: String, artist: String?, album: String?)
    /// Server hat die ID definitiv nicht (mehr) — kein Netzwerk-/Auth-Fehler.
    case definitelyNotFound
    /// Netzwerk-, Auth- oder sonstiger Fehler — Zeile bleibt unangetastet, kein Rückschluss möglich.
    case otherError
}

/// Ein Kandidat aus der Metadaten-Suche (Titel+Artist+Album).
nonisolated struct PlayLogSearchCandidate: Equatable, Sendable {
    let songId: String
    let title: String
    let artist: String?
    let album: String?
}

/// Ergebnis der Abstimmung für einen einzelnen im Log gespeicherten Song.
nonisolated enum PlayLogReconciliationOutcome: Equatable, Sendable {
    /// ID hat aufgelöst — Metadaten werden (unabhängig vom bisherigen Stand) vom Server übernommen.
    case refreshed(title: String, artist: String?, album: String?)
    /// ID war tot, aber Titel+Artist+Album fanden serverseitig genau einen Treffer — ID reparieren.
    case repaired(newSongId: String, title: String, artist: String?, album: String?)
    /// Weder ID noch Metadaten lösen serverseitig auf — nichts mehr rekonstruierbar.
    case delete
    /// Nicht entscheidbar (Netzwerkfehler bei der ID-Prüfung, oder mehrdeutiger Metadaten-Treffer) —
    /// Zeile bleibt unangetastet, wird beim nächsten Lauf erneut geprüft.
    case skip
}

/// Reine Entscheidungslogik für den Database-Cleanup-Task: pro Song wird die ID und das
/// Titel+Artist+Album-Paket als zwei unabhängige Wege behandelt, denselben Song zu finden.
/// Netzwerk/DB sind über injizierte Closures entkoppelt, damit sich jeder Fall ohne echten
/// Server/echte Datenbank testen lässt (gleiches Muster wie CloudKitDeletionLogic).
nonisolated enum PlayLogReconciliationLogic {
    static func reconcile(
        songId: String,
        storedTitle: String?,
        storedArtist: String?,
        storedAlbum: String?,
        lookupById: (String) async -> PlayLogIdLookupResult,
        searchCandidates: (String) async -> [PlayLogSearchCandidate]
    ) async -> PlayLogReconciliationOutcome {
        switch await lookupById(songId) {
        case .found(let title, let artist, let album):
            return .refreshed(title: title, artist: artist, album: album)
        case .otherError:
            return .skip
        case .definitelyNotFound:
            break
        }

        // Keine gespeicherten Metadaten und die ID ist tot — nichts, worüber sich der Song
        // noch finden ließe.
        guard let storedTitle else { return .delete }

        let candidates = await searchCandidates(storedTitle)
        let matches = candidates.filter {
            $0.title == storedTitle && $0.artist == storedArtist && $0.album == storedAlbum
        }

        guard matches.count <= 1 else { return .skip }
        guard let match = matches.first else { return .delete }
        return .repaired(newSongId: match.songId, title: match.title, artist: match.artist, album: match.album)
    }
}
