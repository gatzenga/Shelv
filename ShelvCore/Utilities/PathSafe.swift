import Foundation

extension String {
    /// Macht einen server-gelieferten Identifier sicher als einzelne Pfad-Komponente.
    ///
    /// Subsonic-/Navidrome-IDs sind normalerweise alphanumerisch — diese bleiben unverändert.
    /// Ein bösartiger/kompromittierter Server könnte aber IDs mit `/`, `\` oder führenden
    /// Punkten liefern und damit über `appendingPathComponent` aus dem Zielordner ausbrechen
    /// (Path-Traversal). Ohne Separatoren ist kein Verzeichniswechsel mehr möglich.
    nonisolated var pathSafeComponent: String {
        var s = self
        for separator in ["/", "\\", "\0", ":"] {
            s = s.replacingOccurrences(of: separator, with: "_")
        }
        while s.hasPrefix(".") { s.removeFirst() }   // ".." / versteckte Komponenten neutralisieren
        return s.isEmpty ? "_" : s
    }

    /// Liefert sichere ID-Kandidaten fuer Dateinamen, die optional eine bekannte Dateiendung tragen.
    nonisolated func pathSafeComponentFileNameCandidates(knownFileExtensions: Set<String>) -> Set<String> {
        var candidates: Set<String> = [self]
        guard let dotIndex = lastIndex(of: ".") else { return candidates }

        let extensionStart = index(after: dotIndex)
        guard extensionStart < endIndex else { return candidates }

        let ext = String(self[extensionStart...]).lowercased()
        guard knownFileExtensions.contains(ext) else { return candidates }

        let stem = String(self[..<dotIndex])
        if !stem.isEmpty {
            candidates.insert(stem)
        }
        return candidates
    }
}
