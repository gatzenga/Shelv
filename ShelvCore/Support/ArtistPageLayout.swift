import Foundation

/// Sizing shared by the artist pages of every platform.
nonisolated enum ArtistPageLayout {
    /// Related artists shown in the "fans also like" row.
    static let similarArtistLimit = 12

    /// Related artists asked of the server. The server only returns artists it
    /// has in the library, but some of those have no album of their own (they
    /// are only credited on a track) and are not shown. Asking for more than
    /// `similarArtistLimit` keeps those from taking places away from artists
    /// that can be opened. `getArtistInfo2` returns none at all when this is zero.
    static let similarArtistRequestCount = 50

    /// The related artists worth showing: the first ones, in the server's
    /// order, that have at least one album.
    static func shownSimilarArtists(from artists: [Artist]?) -> [Artist] {
        Array((artists ?? []).filter { ($0.albumCount ?? 0) > 0 }.prefix(similarArtistLimit))
    }
}
