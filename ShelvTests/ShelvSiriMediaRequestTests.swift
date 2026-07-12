#if os(iOS) || os(tvOS) || os(watchOS)
import Intents
import XCTest

final class ShelvSiriMediaRequestTests: XCTestCase {
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

        let request = ShelvSiriMediaRequest(intent: intent)

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
        let original = ShelvSiriMediaRequest(intent: INPlayMediaIntent(
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
        XCTAssertEqual(ShelvSiriMediaRequest(identifier: identifier), original)
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
        let request = ShelvSiriMediaRequest(intent: INPlayMediaIntent(
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

    func testArtistRequestDoesNotTurnSelfTitledAlbumIntoTheQuery() {
        let search = INMediaSearch(
            mediaType: .artist,
            sortOrder: .unknown,
            mediaName: "Dire Straits",
            artistName: "Dire Straits",
            albumName: "Dire Straits",
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: nil
        )
        let request = ShelvSiriMediaRequest(intent: INPlayMediaIntent(
            mediaItems: nil,
            mediaContainer: nil,
            playShuffled: true,
            playbackRepeatMode: .none,
            resumePlayback: nil,
            playbackQueueLocation: .now,
            playbackSpeed: nil,
            mediaSearch: search
        ))

        XCTAssertEqual(request.mediaType, .artist)
        XCTAssertEqual(request.query, "Dire Straits")
        XCTAssertTrue(request.playShuffled)
    }

    func testStationRequestPreservesSeedAndArtist() {
        let search = INMediaSearch(
            mediaType: .musicStation,
            sortOrder: .unknown,
            mediaName: "Sultans of Swing",
            artistName: "Dire Straits",
            albumName: nil,
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: nil
        )
        let request = ShelvSiriMediaRequest(intent: INPlayMediaIntent(
            mediaItems: nil,
            mediaContainer: nil,
            playShuffled: false,
            playbackRepeatMode: .none,
            resumePlayback: nil,
            playbackQueueLocation: .now,
            playbackSpeed: nil,
            mediaSearch: search
        ))

        XCTAssertEqual(request.mediaType, .musicStation)
        XCTAssertEqual(request.query, "Sultans of Swing by Dire Straits")
    }
}
#endif
