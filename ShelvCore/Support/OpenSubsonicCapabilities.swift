import Foundation

/// Names of the OpenSubsonic extensions Shelv knows how to take advantage of.
///
/// Servers advertise what they implement through `getOpenSubsonicExtensions`.
/// Anything not advertised must not be called: classic Subsonic servers answer
/// those endpoints with an error, and Navidrome returns 404 for an extension
/// whose backing plugin is missing.
nonisolated enum OpenSubsonicExtension {
    /// Structured lyrics. Version 2 adds word and syllable timing behind `enhanced=true`.
    static let songLyrics = "songLyrics"
    /// Audio similarity: `getSonicSimilarTracks` and `findSonicPath`.
    static let sonicSimilarity = "sonicSimilarity"
    /// `getTopSongs` accepts an artist id rather than a name.
    static let topSongsByArtistId = "topSongsByArtistId"
    /// Credentials sent as an API key instead of an MD5 of salt and password.
    static let apiKeyAuthentication = "apiKeyAuthentication"
    /// Seeking inside a transcoded stream.
    static let transcodeOffset = "transcodeOffset"
    /// Credentials sent in a form body instead of the query string.
    static let formPost = "formPost"
}

/// What one server advertised, with the versions it supports per extension.
nonisolated struct OpenSubsonicCapabilities: Equatable, Sendable {
    /// A server that advertised nothing, or was never asked. Supports nothing.
    static let none = OpenSubsonicCapabilities(extensions: [:])

    private let extensions: [String: Set<Int>]

    init(extensions: [String: Set<Int>]) {
        self.extensions = extensions
    }

    init(advertised: [(name: String, versions: [Int])]) {
        // A server may repeat a name; merge rather than let the last one win.
        self.extensions = advertised.reduce(into: [:]) { result, entry in
            result[entry.name, default: []].formUnion(entry.versions)
        }
    }

    /// True when the server implements `name` at `version` or better.
    ///
    /// Versions are independent numbers rather than a range, so a server that
    /// advertises only version 2 still answers version 1 requests: the spec
    /// requires later versions to stay backwards compatible.
    func supports(_ name: String, version: Int = 1) -> Bool {
        guard let versions = extensions[name] else { return false }
        return versions.contains { $0 >= version }
    }

    var isEmpty: Bool { extensions.isEmpty }
}
