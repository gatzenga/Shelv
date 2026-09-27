import XCTest

final class LastFMTests: XCTestCase {
    // MARK: - Signature

    func testSignatureSortsParametersAndSkipsFormat() {
        let parameters = [
            "method": "auth.getSession",
            "api_key": "key",
            "token": "tok",
            "format": "json",
        ]
        // md5("api_keykeymethodauth.getSessiontokentoksecret")
        XCTAssertEqual(
            LastFMClient.signature(for: parameters, sharedSecret: "secret"),
            "04e870be4bb79756721b7bc1937fe83d"
        )
    }

    func testAuthorizationURLCarriesTokenAndOptionalCallback() throws {
        let withCallback = try XCTUnwrap(
            LastFMClient.authorizationURL(apiKey: "key", token: "tok", callback: "shelv://lastfm-auth")
        )
        let items = URLComponents(url: withCallback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "token" }?.value, "tok")
        XCTAssertEqual(items.first { $0.name == "cb" }?.value, "shelv://lastfm-auth")

        let withoutCallback = try XCTUnwrap(
            LastFMClient.authorizationURL(apiKey: "key", token: "tok", callback: nil)
        )
        XCTAssertFalse(withoutCallback.absoluteString.contains("cb="))
    }

    // MARK: - Matching

    func testMatchesOnArtistAndTitleEvenWhenTheAlbumDiffers() {
        // A self-made "Singles" album does not exist on Last.fm under the artist.
        let track = LastFMTrack(title: "Heroes", artist: "David Bowie", album: "\"Heroes\"")
        let song = makeSong(id: "1", title: "Heroes", artist: "David Bowie", album: "Singles")
        XCTAssertEqual(LastFMTrackMatcher.bestMatch(for: track, in: [song])?.id, "1")
    }

    func testRejectsSameTitleByAnotherArtist() {
        let track = LastFMTrack(title: "Hurt", artist: "Nine Inch Nails", album: nil)
        let cover = makeSong(id: "cash", title: "Hurt", artist: "Johnny Cash")
        XCTAssertNil(LastFMTrackMatcher.bestMatch(for: track, in: [cover]))
    }

    func testPrefersExactTitleOverStrippedVersionAndAlbumBreaksTies() {
        let track = LastFMTrack(title: "Song", artist: "Band", album: "Record")
        let live = makeSong(id: "live", title: "Song (Live)", artist: "Band", album: "Record", playCount: 40)
        let other = makeSong(id: "other", title: "Song", artist: "Band", album: "Best Of")
        let studio = makeSong(id: "studio", title: "Song", artist: "Band", album: "Record")
        XCTAssertEqual(LastFMTrackMatcher.bestMatch(for: track, in: [live, other, studio])?.id, "studio")
    }

    func testFallsBackToStrippedTitleForVersionSuffixes() {
        let track = LastFMTrack(title: "Heart of Gold - 2009 Remaster", artist: "Neil Young", album: nil)
        let song = makeSong(id: "1", title: "Heart Of Gold", artist: "Neil Young")
        XCTAssertEqual(LastFMTrackMatcher.bestMatch(for: track, in: [song])?.id, "1")
    }

    func testMatchesCollaborationsAndDiacritics() {
        let track = LastFMTrack(title: "Déjà Vu", artist: "Artist A feat. Artist B", album: nil)
        let song = makeSong(id: "1", title: "Deja Vu", artist: "Artist A & Artist C")
        XCTAssertEqual(LastFMTrackMatcher.bestMatch(for: track, in: [song])?.id, "1")
    }

    func testSearchQueriesStartWithArtistAndTitleAndAreUnique() {
        let queries = LastFMTrackMatcher.searchQueries(
            for: LastFMTrack(title: "Song (Remastered)", artist: "Band feat. Guest", album: nil)
        )
        XCTAssertEqual(queries, ["Band Song", "Song", "Song (Remastered)"])
    }

    private func makeSong(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        playCount: Int? = nil
    ) -> Song {
        Song(id: id, title: title, artist: artist, album: album, playCount: playCount)
    }
}
