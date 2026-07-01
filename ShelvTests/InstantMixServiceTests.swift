import XCTest

final class InstantMixServiceTests: XCTestCase {
    func testMixQueueStartsWithSeedAndRemovesDuplicateSeed() {
        let seed = song("seed")
        let queue = InstantMixQueueBuilder.mixQueue(
            startingWith: seed,
            followedBy: [
                song("similar-1"),
                song("seed"),
                song("similar-2"),
                song("similar-1")
            ]
        )

        XCTAssertEqual(queue.map(\.id), ["seed", "similar-1", "similar-2"])
    }

    func testArtistSeedCandidatesUseArtistIdBeforeNameFallback() {
        let artist = Artist(id: "artist-1", name: "Björk")
        let candidates = InstantMixQueueBuilder.artistSeedCandidates(
            from: [
                song("exact-id", artist: nil, artistId: "artist-1"),
                song("same-name", artist: "Bjork", artistId: nil),
                song("other-id-same-name", artist: "Björk", artistId: "artist-2"),
                song("other-name", artist: "Other Artist", artistId: nil),
                song("missing-artist", artist: nil, artistId: nil)
            ],
            for: artist
        )

        XCTAssertEqual(candidates.map(\.id), ["exact-id", "same-name"])
    }

    func testRandomSeedAvoidsPreviousSongWhenAlternativesExist() {
        let seed = InstantMixQueueBuilder.randomSeed(
            from: [song("previous"), song("next")],
            avoiding: "previous"
        )

        XCTAssertEqual(seed?.id, "next")
    }

    private func song(_ id: String, artist: String? = nil, artistId: String? = nil) -> Song {
        Song(
            id: id,
            title: id,
            artist: artist,
            artistId: artistId
        )
    }
}
