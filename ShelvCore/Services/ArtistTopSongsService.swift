import Foundation

/// Ranked top songs for the artist detail pages.
///
/// By default the ranking comes from the play counts the server reports for
/// the artist's own tracks, so the section shows what was actually listened to
/// on this server. `getTopSongs` is deliberately not used: Navidrome answers it
/// from whatever metadata agents it has configured, which makes the result
/// depend on the server setup and not on the listener.
///
/// With the Top Songs option of the Last.fm settings turned on, Last.fm's
/// popular tracks for the artist are matched to the library instead. If that
/// yields nothing, the play counts are used so the section is not left empty.
///
/// The ordering itself lives in `ArtistTopSongsRanking`.
nonisolated enum ArtistTopSongsService {
    static func topSongs(
        artistName: String,
        albums: [Album],
        limit: Int = ArtistTopSongsRanking.limit,
        loadAlbumSongs: @escaping @Sendable (String) async -> [Song]
    ) async -> [Song] {
        if LastFMCredentialStore.usesLastFMTopSongs,
           let ranked = await lastFMTopSongs(
               artistName: artistName,
               albums: albums,
               limit: limit,
               loadAlbumSongs: loadAlbumSongs
           ) {
            return ranked
        }
        return await playCountTopSongs(albums: albums, limit: limit, loadAlbumSongs: loadAlbumSongs)
    }

    private static func playCountTopSongs(
        albums: [Album],
        limit: Int,
        loadAlbumSongs: @escaping @Sendable (String) async -> [Song]
    ) async -> [Song] {
        let scanned = ArtistTopSongsRanking.fallbackAlbums(from: albums)
        guard !scanned.isEmpty else { return [] }

        let songs = await PlaybackContentResolver.artistSongs(
            from: scanned,
            loadAlbumSongs: loadAlbumSongs
        )
        return ArtistTopSongsRanking.rankByPlayCount(songs, limit: limit)
    }

    /// `nil` when Last.fm is not usable or none of its tracks is in the
    /// library, which sends the caller to the play counts.
    private static func lastFMTopSongs(
        artistName: String,
        albums: [Album],
        limit: Int,
        loadAlbumSongs: @escaping @Sendable (String) async -> [Song]
    ) async -> [Song]? {
        let scanned = ArtistTopSongsRanking.lastFMAlbums(from: albums)
        guard !scanned.isEmpty,
              let tracks = await LastFMService.shared.artistTopTracks(
                  artistName: artistName,
                  limit: ArtistTopSongsRanking.lastFMTrackCount
              )
        else { return nil }

        let songs = await PlaybackContentResolver.artistSongs(
            from: scanned,
            loadAlbumSongs: loadAlbumSongs
        )
        let ranked = ArtistTopSongsRanking.rankLastFMTracks(tracks, in: songs, limit: limit)
        guard !ranked.isEmpty else {
            ExternalServicesLog.failure("Top Songs: none of \(tracks.count) Last.fm tracks for \(artistName) is in your library, using play counts")
            return nil
        }
        ExternalServicesLog.success("Top Songs: \(ranked.count) of \(tracks.count) Last.fm tracks for \(artistName) found in your library")
        return ranked
    }
}
