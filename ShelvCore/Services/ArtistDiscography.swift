import Foundation

/// The discography filter of the artist page: albums on one side, singles and
/// EPs on the other.
nonisolated enum ArtistReleaseGroup: String, CaseIterable, Sendable {
    case all
    case albums
    case singlesAndEPs
}

/// Sorts an artist's releases into albums and short releases.
///
/// OpenSubsonic servers report `releaseTypes` per album, which is the only
/// authoritative answer. Servers that don't are read from track count and
/// running time instead, the same signals a listener uses when looking at a
/// release with two tracks on it.
nonisolated enum ArtistDiscography {
    /// A release with at most this many tracks is a single or an EP.
    static let shortReleaseTrackLimit = 3

    /// Up to this many tracks still counts as an EP when the running time stays
    /// under `epDurationLimit`.
    static let epTrackLimit = 6

    /// 30 minutes, the usual boundary between an EP and an album.
    static let epDurationLimit = 30 * 60

    static func group(for album: Album) -> ArtistReleaseGroup {
        if let declared = declaredGroup(for: album) { return declared }
        return inferredGroup(for: album)
    }

    /// The server's own answer, when it gives one.
    static func declaredGroup(for album: Album) -> ArtistReleaseGroup? {
        guard let types = album.releaseTypes, !types.isEmpty else { return nil }
        let normalized = types.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        if normalized.contains(where: { $0 == "single" || $0 == "ep" }) { return .singlesAndEPs }
        return .albums
    }

    /// Track count and running time, for servers without `releaseTypes`.
    static func inferredGroup(for album: Album) -> ArtistReleaseGroup {
        let trackCount = album.songCount ?? 0
        guard trackCount > 0 else { return .albums }
        if trackCount <= shortReleaseTrackLimit { return .singlesAndEPs }
        if trackCount <= epTrackLimit, let duration = album.duration, duration < epDurationLimit {
            return .singlesAndEPs
        }
        return .albums
    }

    static func filter(_ albums: [Album], to group: ArtistReleaseGroup) -> [Album] {
        guard group != .all else { return albums }
        return albums.filter { self.group(for: $0) == group }
    }

    /// The shelves the grid layouts render, in order.
    ///
    /// Splitting says something only when the artist has both kinds of
    /// release. With one kind, one shelf carries the whole discography, and
    /// naming it depends on where the answer came from: a server that declared
    /// `releaseTypes` can be quoted, a track-count guess cannot. A library that
    /// holds a single downloaded track of an album looks exactly like a pile of
    /// singles, and shelving it under "Singles & EPs" leaves the albums shelf
    /// empty on an artist whose albums the listener owns.
    static func shelfGroups(for albums: [Album]) -> [ArtistReleaseGroup] {
        guard let first = albums.first else { return [] }
        guard availableGroups(for: albums).isEmpty else { return [.albums, .singlesAndEPs] }

        let onlyGroup = group(for: first)
        let serverStayedSilent = albums.allSatisfy { declaredGroup(for: $0) == nil }
        if onlyGroup == .singlesAndEPs, serverStayedSilent { return [.all] }
        return [onlyGroup]
    }

    /// The filter is only worth showing when the artist actually has both kinds
    /// of release. One button that filters nothing is noise.
    static func availableGroups(for albums: [Album]) -> [ArtistReleaseGroup] {
        var hasAlbums = false
        var hasShortReleases = false
        for album in albums {
            switch group(for: album) {
            case .albums: hasAlbums = true
            case .singlesAndEPs: hasShortReleases = true
            case .all: break
            }
            if hasAlbums && hasShortReleases { return ArtistReleaseGroup.allCases }
        }
        return []
    }
}
