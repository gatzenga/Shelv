import Foundation

/// Toleranter Date-Decoder für Subsonic-Modelle.
///
/// Deckt alle Decode-Pfade ab, die in der App vorkommen:
/// - iOS-API: `JSONDecoder` mit custom `dateDecodingStrategy` → `decode(Date.self)` greift.
/// - Player-State/Caches: Default-Encoder speichert `Date` als Double → `decode(Date.self)` greift.
/// - macOS-API & macOS-Altdaten (UserDefaults-Queue der alten Desktop-App):
///   `starred`/`created` liegen als ISO8601-String vor → String-Fallback greift.
nonisolated enum FlexibleDate {
    private static let isoFractionalStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let isoStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false
    )

    static func parseISOString(_ raw: String) -> Date? {
        let normalized = normalizedISOString(raw)
        return (try? isoFractionalStyle.parse(normalized))
            ?? (try? isoStyle.parse(normalized))
    }

    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let raw = try? container.decodeIfPresent(String.self, forKey: key), !raw.isEmpty {
            return parseISOString(raw)
        }
        if let date = try? container.decodeIfPresent(Date.self, forKey: key) { return date }
        return nil
    }

    private static func normalizedISOString(_ raw: String) -> String {
        guard let dotRange = raw.range(of: ".") else { return raw }

        let timezoneRange = raw.range(of: "Z", options: .backwards)
            ?? raw.range(of: "+", range: dotRange.upperBound..<raw.endIndex)
            ?? raw.range(of: "-", options: .backwards, range: dotRange.upperBound..<raw.endIndex)
        guard let timezoneRange,
              dotRange.upperBound <= timezoneRange.lowerBound
        else { return raw }

        let fractional = String(raw[dotRange.upperBound..<timezoneRange.lowerBound])
        let milliseconds = String(fractional.prefix(3))
            .padding(toLength: 3, withPad: "0", startingAt: 0)
        return String(raw[..<dotRange.lowerBound])
            + "."
            + milliseconds
            + String(raw[timezoneRange.lowerBound...])
    }
}
