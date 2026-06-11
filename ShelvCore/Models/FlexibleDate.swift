import Foundation

/// Toleranter Date-Decoder für Subsonic-Modelle.
///
/// Deckt alle Decode-Pfade ab, die in der App vorkommen:
/// - iOS-API: `JSONDecoder` mit custom `dateDecodingStrategy` → `decode(Date.self)` greift.
/// - Player-State/Caches: Default-Encoder speichert `Date` als Double → `decode(Date.self)` greift.
/// - macOS-API & macOS-Altdaten (UserDefaults-Queue der alten Desktop-App):
///   `starred`/`created` liegen als ISO8601-String vor → String-Fallback greift.
enum FlexibleDate {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let date = try? container.decodeIfPresent(Date.self, forKey: key) { return date }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key), !raw.isEmpty {
            return isoFractional.date(from: raw) ?? iso.date(from: raw)
        }
        return nil
    }
}
