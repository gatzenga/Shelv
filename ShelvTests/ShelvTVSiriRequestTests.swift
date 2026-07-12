#if os(iOS) || os(tvOS) || os(watchOS)
import Intents
import XCTest

final class ShelvTVSiriRequestTests: XCTestCase {
    func testSongRequestPreservesTitleArtistAndPlaybackOptions() throws {
        let search = INMediaSearch(
            mediaType: .song,
            sortOrder: .unknown,
            mediaName: "Demons",
            artistName: "Imagine Dragons",
            albumName: "Evolve",
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: nil
        )
        let intent = INPlayMediaIntent(
            mediaItems: nil,
            mediaContainer: nil,
            playShuffled: true,
            playbackRepeatMode: .none,
            resumePlayback: nil,
            playbackQueueLocation: .next,
            playbackSpeed: nil,
            mediaSearch: search
        )

        let request = ShelvTVSiriRequest(intent: intent)

        XCTAssertEqual(request.mediaType, .song)
        XCTAssertEqual(request.query, "Demons by Imagine Dragons")
        XCTAssertTrue(request.playShuffled)
        XCTAssertEqual(request.playbackQueueLocationRawValue, INPlaybackQueueLocation.next.rawValue)
    }

    func testResolvedIdentifierRoundTripsAcrossExtensionAndApp() throws {
        let search = INMediaSearch(
            mediaType: .album,
            sortOrder: .unknown,
            mediaName: "On Every Street",
            artistName: "Dire Straits",
            albumName: "On Every Street",
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: nil
        )
        let original = ShelvTVSiriRequest(intent: INPlayMediaIntent(
            mediaItems: nil,
            mediaContainer: nil,
            playShuffled: false,
            playbackRepeatMode: .all,
            resumePlayback: nil,
            playbackQueueLocation: .now,
            playbackSpeed: nil,
            mediaSearch: search
        ))

        let identifier = try XCTUnwrap(original.identifier)
        XCTAssertEqual(ShelvTVSiriRequest(identifier: identifier), original)
        XCTAssertEqual(original.query, "On Every Street by Dire Straits")
    }

    func testGenericMusicRequestCanPlayWithoutAQuery() {
        let search = INMediaSearch(
            mediaType: .music,
            sortOrder: .unknown,
            mediaName: nil,
            artistName: nil,
            albumName: nil,
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: nil
        )
        let request = ShelvTVSiriRequest(intent: INPlayMediaIntent(
            mediaItems: nil,
            mediaContainer: nil,
            playShuffled: false,
            playbackRepeatMode: .unknown,
            resumePlayback: nil,
            playbackQueueLocation: .unknown,
            playbackSpeed: nil,
            mediaSearch: search
        ))

        XCTAssertTrue(request.query.isEmpty)
        XCTAssertTrue(request.isActionableWithoutQuery)
    }
}
#endif
