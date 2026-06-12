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
}
